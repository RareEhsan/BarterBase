# BarterBase

Fee-free P2P ERC-721 barter marketplace on Base.

## V1 scope
- ERC-721 for ERC-721 swaps
- Optional native ETH sweetener
- Public or private offers
- Specific NFT or any NFT from a collection
- Expiry and cancellation
- Fully escrowed counter-offers (max **5 active** per parent offer — cancelled/expired counters free their slot)
- Atomic settlement
- Wallet-match discovery using the connected wallet's NFT inventory
- Shareable offer URLs
- No platform fee; users pay Base gas only

## Deployment order (follow strictly)

1. **Compile** — `BarterBase.sol` with Solidity `0.8.20` (optimizer 200 runs; no via-IR needed).
2. **Base Sepolia (testnet)** — deploy and run the FULL flow with a test ERC-721:
   create → accept → cancel → expire → counter create/accept/cancel/expire → `withdrawPendingETH`.
3. **Full testing** — verify every event, every revert path, escrow returns, and the
   `activeCounterCount` invariant (`activeCounterCount[p]` must equal the number of active counters for offer `p` at all times).
4. **Security review** — independent review of reentrancy, approval flow, ETH credit path, and front-running exposure before any real assets.
5. **Base Mainnet** — only after steps 1–4 pass.

## Deploy safely
1. Open `BarterBase.sol` in Remix.
2. Compile with Solidity `0.8.20` or a compatible `0.8.x` compiler.
3. Connect Remix to **Base Sepolia** and deploy first.
4. **Before using real NFTs, test the full flow on Base Sepolia with a test ERC-721.**
5. After testing + security review, deploy to Base Mainnet and put the address in `index.html` as `CONFIG.CONTRACT`.

## Frontend configuration (secrets)

`index.html` reads runtime config from `window.BarterBaseConfig` (set it in an inline
`<script>` BEFORE the main script) falling back to placeholders:

```html
<script>
  // Injected at build/deploy time — do NOT commit real keys to git.
  window.BarterBaseConfig = {
    CONTRACT: '0x…',        // deployed BarterBaseV3 address
    ALCHEMY_KEY: '…'        // see restrictions below
  };
</script>
```

### Alchemy API key rules
- **Never ship a private/unrestricted key in the frontend bundle.** Anything in the
  browser is public.
- In the Alchemy dashboard, apply **domain allowlist restrictions** (only
  `barterbase.vercel.app` and `localhost`) and set a **throughput / capacity limit**
  so a leaked key cannot be abused beyond your free tier.
- For production, prefer a tiny serverless proxy that injects the key server-side and
  rate-limits per IP. The frontend then calls your proxy instead of Alchemy directly.
- Rotate the key if it was ever committed or shared.

## Important
The contract is intentionally immutable and has no owner/admin upgrade role. There is no platform fee.
The frontend is a static prototype. For production, use an indexed event backend (The Graph /
Alchemy webhooks) for large offer volumes rather than scanning the contract one offer at a time.

Do not put private keys or seed phrases in this project.
