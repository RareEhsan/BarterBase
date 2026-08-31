// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

/**
 * @title BarterBase
 * @notice Fee-free, non-custodial P2P ERC-721 barter on Base.
 *         Makers escrow one NFT and optional ETH. Takers provide the requested NFT.
 *         Counter-offers are fully on-chain and escrow their own NFT + ETH immediately.
 *
 *         Platform fee: 0. Users pay only Base network gas.
 *         Supported assets: ERC-721 + native ETH only.
 */
contract BarterBaseV3 is IERC721Receiver {
    struct Offer {
        address maker;
        address taker; // zero = public
        address offeredCollection;
        uint256 offeredTokenId;
        uint256 sweetenerWei;
        address wantedCollection;
        uint256 wantedTokenId;
        bool wantedAny;
        uint64 expiry; // zero = no expiry
        uint256 parentOfferId; // zero = root offer
        bool active;
    }

    struct CounterOffer {
        uint256 parentOfferId;
        address maker;
        address offeredCollection;
        uint256 offeredTokenId;
        uint256 sweetenerWei;
        uint64 expiry;
        bool active;
    }

    uint256 public nextOfferId = 1;
    uint256 public nextCounterOfferId = 1;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => CounterOffer) public counterOffers;
    mapping(uint256 => uint256[]) private _counterIdsByParent;

    uint256 public constant MAX_COUNTERS_PER_OFFER = 5;
    // Tracks only ACTIVE counters per parent offer, so cancelled/expired/invalidated
    // counters do not permanently consume a slot (fixes lifetime-only limitation).
    // Invariant: activeCounterCount[p] == number of counterOffers with active==true for parent p.
    mapping(uint256 => uint256) public activeCounterCount;
    mapping(address => uint256) public pendingETH;

    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "REENTRANT");
        _lock = 2;
        _;
        _lock = 1;
    }

    event OfferCreated(
        uint256 indexed offerId,
        address indexed maker,
        address indexed offeredCollection,
        uint256 offeredTokenId,
        uint256 sweetenerWei,
        address wantedCollection,
        uint256 wantedTokenId,
        bool wantedAny,
        uint64 expiry,
        address taker,
        uint256 parentOfferId
    );
    event OfferAccepted(uint256 indexed offerId, address indexed taker, uint256 takerTokenId);
    event OfferCancelled(uint256 indexed offerId);
    event OfferExpired(uint256 indexed offerId);

    event CounterOfferCreated(
        uint256 indexed counterOfferId,
        uint256 indexed parentOfferId,
        address indexed maker,
        address offeredCollection,
        uint256 offeredTokenId,
        uint256 sweetenerWei,
        uint64 expiry
    );
    event CounterOfferAccepted(uint256 indexed counterOfferId, uint256 indexed parentOfferId);
    event CounterOfferCancelled(uint256 indexed counterOfferId);
    event CounterOfferExpired(uint256 indexed counterOfferId);

    function createOffer(
        address taker,
        address offeredCollection,
        uint256 offeredTokenId,
        uint256 sweetenerWei,
        address wantedCollection,
        uint256 wantedTokenId,
        bool wantedAny,
        uint64 expiry
    ) external payable nonReentrant returns (uint256 offerId) {
        require(offeredCollection != address(0) && wantedCollection != address(0), "BAD_COLLECTION");
        require(taker == address(0) || taker != msg.sender, "SELF_TAKER");
        require(msg.value == sweetenerWei, "BAD_ETH_VALUE");
        require(expiry == 0 || expiry > block.timestamp, "BAD_EXPIRY");

        IERC721(offeredCollection).safeTransferFrom(msg.sender, address(this), offeredTokenId);

        // Stack-too-deep fix: group params in memory structs instead of many locals.
        offerId = nextOfferId++;
        offers[offerId] = Offer({
            maker: msg.sender,
            taker: taker,
            offeredCollection: offeredCollection,
            offeredTokenId: offeredTokenId,
            sweetenerWei: sweetenerWei,
            wantedCollection: wantedCollection,
            wantedTokenId: wantedTokenId,
            wantedAny: wantedAny,
            expiry: expiry,
            parentOfferId: 0,
            active: true
        });
        emit OfferCreated(
            offerId, offers[offerId].maker, offers[offerId].offeredCollection, offers[offerId].offeredTokenId,
            offers[offerId].sweetenerWei, offers[offerId].wantedCollection, offers[offerId].wantedTokenId,
            offers[offerId].wantedAny, offers[offerId].expiry, offers[offerId].taker, 0
        );
    }

    function acceptOffer(uint256 offerId, uint256 takerTokenId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "OFFER_NOT_ACTIVE");
        require(o.taker == address(0) || o.taker == msg.sender, "NOT_ALLOWED_TAKER");
        require(o.expiry == 0 || block.timestamp <= o.expiry, "OFFER_EXPIRED");
        if (!o.wantedAny) require(takerTokenId == o.wantedTokenId, "WRONG_TOKEN");
        require(IERC721(o.wantedCollection).ownerOf(takerTokenId) == msg.sender, "NOT_TOKEN_OWNER");

        o.active = false;
        _invalidateCounters(offerId, 0);
        IERC721(o.wantedCollection).safeTransferFrom(msg.sender, o.maker, takerTokenId);
        IERC721(o.offeredCollection).safeTransferFrom(address(this), msg.sender, o.offeredTokenId);
        _payOrCredit(msg.sender, o.sweetenerWei);
        emit OfferAccepted(offerId, msg.sender, takerTokenId);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "OFFER_NOT_ACTIVE");
        require(o.maker == msg.sender, "NOT_MAKER");
        o.active = false;
        _invalidateCounters(offerId, 0);
        _returnEscrow(o.maker, o.offeredCollection, o.offeredTokenId, o.sweetenerWei);
        emit OfferCancelled(offerId);
    }

    function expireOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.active, "OFFER_NOT_ACTIVE");
        require(o.expiry != 0 && block.timestamp > o.expiry, "NOT_EXPIRED");
        o.active = false;
        _invalidateCounters(offerId, 0);
        _returnEscrow(o.maker, o.offeredCollection, o.offeredTokenId, o.sweetenerWei);
        emit OfferExpired(offerId);
    }

    /**
     * @dev A counter-offer locks its NFT + ETH immediately. This prevents the counter
     *      maker from disappearing after the original maker accepts the counter.
     *      It is valid only while the parent offer is active.
     */
    function createCounterOffer(
        uint256 parentOfferId,
        address offeredCollection,
        uint256 offeredTokenId,
        uint256 sweetenerWei,
        uint64 expiry
    ) external payable nonReentrant returns (uint256 counterOfferId) {
        Offer storage p = offers[parentOfferId];
        require(p.active, "PARENT_NOT_ACTIVE");
        require(p.maker != msg.sender, "MAKER_CANNOT_COUNTER_SELF");
        require(p.expiry == 0 || block.timestamp <= p.expiry, "PARENT_EXPIRED");
        require(offeredCollection == p.wantedCollection, "WRONG_COLLECTION");
        require(p.wantedAny || offeredTokenId == p.wantedTokenId, "WRONG_TOKEN");
        require(expiry == 0 || expiry > block.timestamp, "BAD_EXPIRY");
        require(msg.value == sweetenerWei, "BAD_ETH_VALUE");
        require(activeCounterCount[parentOfferId] < MAX_COUNTERS_PER_OFFER, "TOO_MANY_COUNTERS");

        IERC721(offeredCollection).safeTransferFrom(msg.sender, address(this), offeredTokenId);

        counterOfferId = nextCounterOfferId++;
        counterOffers[counterOfferId] = CounterOffer({
            parentOfferId: parentOfferId,
            maker: msg.sender,
            offeredCollection: offeredCollection,
            offeredTokenId: offeredTokenId,
            sweetenerWei: sweetenerWei,
            expiry: expiry,
            active: true
        });
        _counterIdsByParent[parentOfferId].push(counterOfferId);
        activeCounterCount[parentOfferId]++;

        emit CounterOfferCreated(counterOfferId, parentOfferId, msg.sender, offeredCollection, offeredTokenId, sweetenerWei, expiry);
    }

    /**
     * @notice Original maker accepts a counter. Parent escrow and counter escrow swap atomically.
     */
    function acceptCounterOffer(uint256 counterOfferId) external nonReentrant {
        CounterOffer storage c = counterOffers[counterOfferId];
        require(c.active, "COUNTER_NOT_ACTIVE");
        require(c.expiry == 0 || block.timestamp <= c.expiry, "COUNTER_EXPIRED");

        Offer storage p = offers[c.parentOfferId];
        require(p.active, "PARENT_NOT_ACTIVE");
        require(p.maker == msg.sender, "ONLY_PARENT_MAKER");
        require(p.expiry == 0 || block.timestamp <= p.expiry, "PARENT_EXPIRED");

        c.active = false;
        p.active = false;
        activeCounterCount[c.parentOfferId]--;
        _invalidateCounters(c.parentOfferId, counterOfferId);

        // Counter maker receives the parent's escrow.
        IERC721(p.offeredCollection).safeTransferFrom(address(this), c.maker, p.offeredTokenId);
        _payOrCredit(c.maker, p.sweetenerWei);

        // Parent maker receives the counter escrow.
        IERC721(c.offeredCollection).safeTransferFrom(address(this), p.maker, c.offeredTokenId);
        _payOrCredit(p.maker, c.sweetenerWei);

        emit CounterOfferAccepted(counterOfferId, c.parentOfferId);
    }

    function cancelCounterOffer(uint256 counterOfferId) external nonReentrant {
        CounterOffer storage c = counterOffers[counterOfferId];
        require(c.active, "COUNTER_NOT_ACTIVE");
        require(c.maker == msg.sender, "NOT_COUNTER_MAKER");
        c.active = false;
        activeCounterCount[c.parentOfferId]--;
        _returnEscrow(c.maker, c.offeredCollection, c.offeredTokenId, c.sweetenerWei);
        emit CounterOfferCancelled(counterOfferId);
    }

    function expireCounterOffer(uint256 counterOfferId) external nonReentrant {
        CounterOffer storage c = counterOffers[counterOfferId];
        require(c.active, "COUNTER_NOT_ACTIVE");
        require((c.expiry != 0 && block.timestamp > c.expiry) || (offers[c.parentOfferId].expiry != 0 && block.timestamp > offers[c.parentOfferId].expiry), "NOT_EXPIRED");
        c.active = false;
        activeCounterCount[c.parentOfferId]--;
        _returnEscrow(c.maker, c.offeredCollection, c.offeredTokenId, c.sweetenerWei);
        emit CounterOfferExpired(counterOfferId);
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) { return offers[offerId]; }
    function getCounterOffer(uint256 counterOfferId) external view returns (CounterOffer memory) { return counterOffers[counterOfferId]; }
    function getCounterOfferIds(uint256 parentOfferId) external view returns (uint256[] memory) { return _counterIdsByParent[parentOfferId]; }

    function _returnEscrow(address to, address collection, uint256 tokenId, uint256 ethAmount) internal {
        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
        _payOrCredit(to, ethAmount);
    }

    function _payOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) pendingETH[to] += amount;
    }

    function withdrawPendingETH() external nonReentrant {
        uint256 amount = pendingETH[msg.sender];
        require(amount > 0, "NO_PENDING_ETH");
        pendingETH[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "WITHDRAW_FAILED");
    }

    function _invalidateCounters(uint256 parentOfferId, uint256 exceptCounterId) internal {
        uint256[] storage ids = _counterIdsByParent[parentOfferId];
        uint256 invalidated;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == exceptCounterId) continue;
            CounterOffer storage c = counterOffers[id];
            if (c.active) {
                c.active = false;
                invalidated++;
                _returnEscrow(c.maker, c.offeredCollection, c.offeredTokenId, c.sweetenerWei);
                emit CounterOfferCancelled(id);
            }
        }
        activeCounterCount[parentOfferId] -= invalidated;
    }

    receive() external payable { revert("DIRECT_ETH_DISABLED"); }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
