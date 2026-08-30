# BarterBase

Fee-free P2P ERC-721 barter marketplace on Base.

## V1 scope
- ERC-721 for ERC-721 swaps
- Optional native ETH sweetener
- Public or private offers
- Specific NFT or any NFT from a collection
- Expiry and cancellation
- Fully escrowed counter-offers (max 5 per parent offer)
- Atomic settlement
- Wallet-match discovery using the connected wallet's NFT inventory
- Shareable offer URLs
- No platform fee; users pay Base gas only

## Deploy safely
1. Open `BarterBase.sol` in Remix.
2. Compile with Solidity `0.8.20` or a compatible `0.8.x` compiler.
3. Connect Remix to Base Mainnet and deploy.
4. **Before using real NFTs, test the full flow on Base Sepolia with a test ERC-721.**
5. Put the deployed address in `index.html` as `CONFIG.CONTRACT`.
6. Put your Alchemy Base NFT API key in `CONFIG.ALCHEMY_KEY`.

## Important
The contract is intentionally immutable and has no owner/admin upgrade role. There is no platform fee.
The frontend is a static prototype. For production, move the Alchemy key behind a serverless proxy or apply strict key restrictions, and use an indexed event backend for large offer volumes rather than scanning the contract one offer at a time.

Do not put private keys or seed phrases in this project.
