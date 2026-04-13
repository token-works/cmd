# [CMD] — TenCommandements

[![CMD](https://cmd.markets/og/og-home.png)](https://cmd.markets)

An on-chain game where community prompts shape an ERC20 contract across **10 rounds**. Each round, any wallet submits a prompt for 0.01 ETH — one is picked at random via Chainlink VRF and applied by the team to produce the next contract version. The winning author receives 1% of total supply. After round 10, the final contract is permanent.

Full rules: [cmd.markets/rules](https://cmd.markets/rules)

## Token

- **Name:** `TenCommandements`
- **Symbol:** `CMD`
- **Supply:** `1,000,000,000` fixed, minted to deployer

## What Can Change

**Locked (immutable):** token identity, supply, constructor mint, core ERC20 surface (`transfer`, `approve`, `transferFrom`, `totalSupply`)

**Open to prompts:** `COMMUNITY_STATE`, `COMMUNITY_LOGIC`, `COMMUNITY_FUNCTIONS`

## Branches

- `round-<id>-opus-4-6-<slug>`
- `round-<id>-gpt-5-4-<slug>`
