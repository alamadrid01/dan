
# DAN — The Avalanche Discovery Engine

**DAN** is a decentralized application discovery network built on Avalanche. It bridges the "Island Effect" by creating an incentivized layer that connects new projects to verified users. Instead of spending budget on bot-heavy Web2 ads, applications deposit rewards directly into DAN for real users to earn by completing meaningful engagement tasks.

## The Three-Actor Ecosystem

DAN creates a direct, incentivized bridge where every participant benefits:

**Advertisers:** New or growing apps that pay only for genuine, verified engagement.
**Publishers:** Established platforms that earn 5% of every reward paid through their site by hosting Discovery Cards.
**Users (Pioneers):** Active Avalanche wallet holders who earn AVAX for exploring and engaging with new projects.

## 🛠 Technical Architecture

The project is built as a hybrid infrastructure to ensure scalability and cost-effectiveness on the Avalanche C-Chain.

### 1. Smart Contract Core (Solidity)
**Chain:** Avalanche C-Chain (Fuji Testnet).
* **Accumulation Model:** Rewards are credited to an internal contract balance. Users withdraw once they reach the **0.5 AVAX threshold** to optimize gas costs.
**Automatic Revenue Split:** Every completion automatically distributes **85% to the User**, **10% to the DAN Treasury**, and **5% to the Publisher**.

### 2. Backend Verifier (Python/FastAPI)
**Verification:** Uses `Web3.py` to poll C-Chain data and verify task completion (e.g., wallet interactions, swaps, or NFT mints).
**Social Credit Score:** A bot-protection layer that checks on-chain history (transaction counts) before approving rewards.
**Discovery Links:** Serves Open Graph metadata so that sharing a quest link on social platforms (like The Arena or X) renders a rich, interactive preview.
### 3. Frontend Dashboards (React)
**User Feed:** A discovery-first UI for users to find active campaigns and claim rewards.
**Advertiser Panel:** A management suite for projects to launch campaigns, set daily caps, and monitor budget exhaustion.
**Publisher SDK:** A simple JavaScript snippet that allows external platforms to embed Discovery Cards and earn passive revenue.

## 📂 Project Structure

```bash
├── contracts/        # Hardhat project: Solidity core logic & unit tests
├── server/           # FastAPI: Verifier, Social Credit Engine, & OG Link API
├── web/              # React: Multi-dashboard frontend & Publisher SDK
└── docs/             # Technical reference and build milestones

```

## 📅 Roadmap
**v1 (Current):** C-Chain deployment, backend polling verification, and Core SDK.
**v2:** Avalanche Warp Messaging (AWM) for cross-chain subnet verification and npm package SDK.
**v3:** Sovereign DAN L1 Subnet for fully gasless interactions.

**Built for the Avalanche Build Games 2026** 

Would you like me to help you create a specific **"Getting Started"** section for developers that explains how to run the `contracts`, `server`, and `web` folders locally?
