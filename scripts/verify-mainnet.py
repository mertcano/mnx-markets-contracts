#!/usr/bin/env python3
"""Compare MNX mainnet contracts with local Foundry builds of this repository.

Reads the shared contracts and vault accounts from the published inventory and
every market's six contracts from the public market registry. It resolves each
proxy to its current ERC-1967 implementation, downloads the runtime code over
public RPC, and reports which compiled artifact (if any) each contract matches.
A match means the runtime bytecode is identical after removing the Solidity
metadata trailer and zeroing the artifact's immutable and library-link ranges.
A factory's code also contains the creation code of the contracts it deploys,
each with its own metadata hash; those hashes are ignored too, and the output
says when.

    forge build
    FOUNDRY_PROFILE=forwarder forge build contracts/MinimalForwarder.sol
    FOUNDRY_PROFILE=deployed-2026-08-06 forge build
    FOUNDRY_PROFILE=deployed-2026-07-18 forge build
    python3 scripts/verify-mainnet.py

Read-only: it sends no transactions and needs no keys.
"""
import argparse
import glob
import json
import os
import sys
import urllib.request
from collections import defaultdict

SCOPE_URL = 'https://docs.mnx.fi/security/mainnet-scope.json'
MARKETS_URL = 'https://api.app.mnx.fi/v0/markets?include_unlaunched=true'
RPC_URL = 'https://mainnet.megaeth.com/rpc'
BUILD_DIRS = ('out', 'out-forwarder', 'out-2026-08-06', 'out-2026-07-18')
IMPLEMENTATION_SLOT = (
    '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
)
HEADERS = {'Content-Type': 'application/json', 'User-Agent': 'curl/8.7.1'}
# Solidity 0.8.26 metadata trailer: CBOR {"ipfs": <multihash>, "solc": 0.8.26}
# followed by its two-byte length, 53 bytes in all. Only the 32-byte digest
# varies.
METADATA_PREFIX = bytes.fromhex('a2646970667358221220')
METADATA_SUFFIX = bytes.fromhex('64736f6c634300081a')
METADATA_LENGTH = bytes.fromhex('0033')
METADATA_SIZE = len(METADATA_PREFIX) + 32 + len(METADATA_SUFFIX) + 2
# Market registry field -> contract, for the six contracts of each market.
MARKET_CONTRACTS = (
    ('contract_address', 'Perpetual'),
    ('trader_address', 'IsolatedTrader'),
    ('adl_address', 'IsolatedADL'),
    ('evaluator_address', 'Evaluator'),
    ('funding_oracle_address', 'FundingOracle'),
    ('oracle_address', 'Price oracle'),
)


def load_json(source):
    if os.path.exists(source):
        return json.load(open(source))
    request = urllib.request.Request(source, headers=HEADERS)
    return json.loads(urllib.request.urlopen(request, timeout=60).read())


def rpc_batch(rpc_url, calls):
    results = []
    for offset in range(0, len(calls), 40):
        chunk = calls[offset:offset + 40]
        body = json.dumps([
            {'jsonrpc': '2.0', 'id': index, 'method': method, 'params': params}
            for index, (method, params) in enumerate(chunk)
        ]).encode()
        request = urllib.request.Request(rpc_url, data=body, headers=HEADERS)
        response = json.loads(urllib.request.urlopen(request, timeout=60).read())
        by_id = {item['id']: item for item in response}
        for index in range(len(chunk)):
            item = by_id[index]
            if 'error' in item:
                raise RuntimeError(f'{chunk[index]}: {item["error"]}')
            results.append(item['result'])
    return results


def is_metadata_trailer(code, start):
    """Whether the METADATA_SIZE bytes at start are a metadata trailer."""
    suffix = start + len(METADATA_PREFIX) + 32
    length = suffix + len(METADATA_SUFFIX)
    return (code[start:start + len(METADATA_PREFIX)] == METADATA_PREFIX
            and code[suffix:length] == METADATA_SUFFIX
            and code[length:start + METADATA_SIZE] == METADATA_LENGTH)


def strip_metadata(code):
    """Remove the code's own metadata trailer. Trailing bytes that are not
    exactly that trailer stay and are compared as code."""
    start = len(code) - METADATA_SIZE
    if start >= 0 and is_metadata_trailer(code, start):
        return code[:start]
    return code


def embedded_metadata_hashes(code):
    """(start, length) of each metadata digest inside the code, such as those
    of the creation code a factory deploys."""
    ranges = []
    start = code.find(METADATA_PREFIX)
    while start >= 0:
        if is_metadata_trailer(code, start):
            ranges.append((start + len(METADATA_PREFIX), 32))
        start = code.find(METADATA_PREFIX, start + 1)
    return ranges


def load_artifacts(build_dir):
    artifacts = []
    pattern = os.path.join(build_dir, '**', '*.json')
    for path in glob.glob(pattern, recursive=True):
        if os.path.join(build_dir, 'build-info') in path:
            continue
        artifact = json.load(open(path))
        deployed = artifact.get('deployedBytecode', {})
        code = deployed.get('object', '0x')
        if len(code) <= 2:
            continue
        ranges = []
        for references in deployed.get('immutableReferences', {}).values():
            ranges += [(r['start'], r['length']) for r in references]
        for libraries in deployed.get('linkReferences', {}).values():
            for references in libraries.values():
                ranges += [(r['start'], r['length']) for r in references]
        hex_chars = list(code[2:])
        for start, length in ranges:
            hex_chars[start * 2:(start + length) * 2] = ['0'] * (length * 2)
        stripped = strip_metadata(bytes.fromhex(''.join(hex_chars)))
        embedded = embedded_metadata_hashes(stripped)
        masked = bytearray(stripped)
        for start, length in embedded:
            masked[start:start + length] = bytes(length)
        settings = artifact['metadata']['settings']
        (source, name), = settings['compilationTarget'].items()
        note = f'{settings["optimizer"]["runs"]:,} runs'
        if embedded:
            noun = 'contract' if len(embedded) == 1 else 'contracts'
            note += (f'; ignores the metadata hashes of the {len(embedded)} '
                     f'{noun} it deploys')
        artifacts.append({
            'id': f'{source}:{name} ({note})',
            'code': bytes(masked),
            'ranges': ranges + embedded,
        })
    return artifacts


def matches(onchain, artifact):
    stripped = strip_metadata(onchain)
    if len(stripped) != len(artifact['code']):
        return False
    masked = bytearray(stripped)
    for start, length in artifact['ranges']:
        masked[start:start + length] = bytes(length)
    return bytes(masked) == artifact['code']


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--out', action='append',
                        help='Foundry output directory (repeatable); '
                             f'default: {", ".join(BUILD_DIRS)}')
    parser.add_argument('--scope', default=SCOPE_URL,
                        help='inventory URL or local JSON file')
    parser.add_argument('--markets', default=MARKETS_URL,
                        help='market registry URL or local JSON file')
    parser.add_argument('--rpc', default=RPC_URL)
    args = parser.parse_args()

    build_dirs = args.out or [d for d in BUILD_DIRS if os.path.isdir(d)]
    artifacts = []
    for build_dir in build_dirs:
        artifacts += load_artifacts(build_dir)

    scope = load_json(args.scope)
    markets = load_json(args.markets)
    entries = [('shared', c['name'], c['address'])
               for c in scope['sharedContracts']]
    entries += [('vault', v['role'], v['address'])
                for v in scope['vaultAccounts']]
    for market in markets:
        entries += [(market['symbol'], name, market[field])
                    for field, name in MARKET_CONTRACTS if market.get(field)]

    # A proxy stores its implementation in the ERC-1967 slot; anything else
    # holds its own code.
    block = hex(int(rpc_batch(args.rpc, [('eth_blockNumber', [])])[0], 16))
    addresses = sorted({address.lower() for _, _, address in entries})
    slots = rpc_batch(args.rpc, [
        ('eth_getStorageAt', [address, IMPLEMENTATION_SLOT, block])
        for address in addresses])
    implementation = {address: '0x' + slot[-40:]
                      for address, slot in zip(addresses, slots)
                      if int(slot, 16) != 0}
    targets = sorted({implementation.get(address, address)
                      for address in addresses})
    codes = dict(zip(targets, rpc_batch(
        args.rpc, [('eth_getCode', [target, block]) for target in targets])))

    verdict = {}
    for target, code in codes.items():
        onchain = bytes.fromhex(code[2:])
        found = [a['id'] for a in artifacts if onchain and matches(onchain, a)]
        verdict[target] = ' | '.join(sorted(found)) or 'NO MATCH'

    print(f'block {int(block, 16)}; {len(entries)} contracts in '
          f'{len(markets)} markets plus shared and vault; '
          f'{len(artifacts)} artifacts from {", ".join(build_dirs)}')
    summary = defaultdict(list)
    unmatched = 0
    for group, name, address in entries:
        result = verdict[implementation.get(address.lower(), address.lower())]
        summary[(name, result)].append(group)
        unmatched += result == 'NO MATCH'
    for (name, result), groups in sorted(summary.items()):
        print(f'{name:40s} {len(groups):3d}x  {result}  [{", ".join(groups)}]')
    print(f'{len(entries) - unmatched} of {len(entries)} contracts match')
    return 1 if unmatched else 0


if __name__ == '__main__':
    sys.exit(main())
