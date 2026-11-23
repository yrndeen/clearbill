// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20Stable {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ClearbillInvoices
/// @notice Stablecoin Invoice + Confirmation of Payee (CoP) settlement protocol for QDay Aevum Testnet (44005).
/// @dev Enforces a mandatory Confirmation-of-Payee step before any 6-decimal tUSD8 can move,
///      holds funds in an escrow review window, and supports immediate payer release, auto-finalization,
///      voluntary payee refund, and clean expiry/cancellation. No admin keys, no upgrade proxies.
contract ClearbillInvoices {
    uint64 public constant MAX_REVIEW_WINDOW = 14 days;
    uint256 public constant MAX_NAME_LEN = 80;
    uint256 public constant MAX_MEMO_LEN = 240;

    enum InvoiceStatus {
        None,
        Issued,
        PayeeConfirmed,
        PaidInEscrow,
        Settled,
        Cancelled,
        Expired,
        Refunded
    }

    struct Invoice {
        uint256 id;
        address payee;
        address payer;
        string payeeDisplayName;
        bytes32 payeeNameHash;
        uint256 amount; // 6-decimal tUSD8 units (1_000_000 = 1.000000 tUSD8)
        uint64 createdAt;
        uint64 dueAt;
        uint64 reviewWindowSec;
        uint64 confirmedAt;
        uint64 paidAt;
        uint64 finalizeAfter;
        bytes32 invoiceRefHash;
        string memo;
        InvoiceStatus status;
    }

    IERC20Stable public immutable token; // Official Aevum tUSD8: 0x456569838f1d43009A91ebA4263147Afd7233483
    uint256 public nextInvoiceId = 1;
    uint256 public totalEscrowed;
    uint256 public totalSettled;

    mapping(uint256 => Invoice) private _invoices;
    mapping(address => uint256[]) private _payeeInvoices;
    mapping(address => uint256[]) private _payerInvoices;

    uint256 private _locked = 1;

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed payee,
        address indexed payer,
        string payeeDisplayName,
        uint256 amount,
        uint64 dueAt,
        uint64 reviewWindowSec,
        bytes32 invoiceRefHash
    );

    event PayeeConfirmed(
        uint256 indexed invoiceId,
        address indexed payer,
        address indexed confirmedPayee,
        bytes32 confirmedNameHash,
        uint64 confirmedAt
    );

    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint64 paidAt,
        uint64 finalizeAfter
    );

    event InvoiceSettled(
        uint256 indexed invoiceId,
        address indexed payee,
        uint256 amount,
        address indexed releasedBy,
        uint64 settledAt
    );

    event InvoiceCancelled(uint256 indexed invoiceId, address indexed payee, uint64 cancelledAt);
    event InvoiceExpired(uint256 indexed invoiceId, address indexed caller, uint64 expiredAt);
    event InvoiceRefunded(
        uint256 indexed invoiceId,
        address indexed payee,
        address indexed payer,
        uint256 amount,
        string reason
    );

    error ZeroAddress();
    error SelfInvoice();
    error ZeroAmount();
    error EmptyDisplayName();
    error DisplayNameTooLong();
    error MemoTooLong();
    error InvalidDueAt();
    error ReviewWindowTooLong();
    error InvoiceNotFound();
    error NotPayer();
    error NotPayee();
    error NotParty();
    error InvalidStatus(InvoiceStatus expected, InvoiceStatus actual);
    error InvoicePastDue();
    error InvoiceNotYetPastDue();
    error PayeeAddressMismatch(address expected, address actual);
    error PayeeNameMismatch();
    error ReviewWindowActive(uint64 finalizeAfter);
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address tUsd8Token_) {
        if (tUsd8Token_ == address(0)) revert ZeroAddress();
        token = IERC20Stable(tUsd8Token_);
    }

    /// @notice Issues a new tUSD8 invoice from msg.sender (payee) to payer.
    function createInvoice(
        address payer,
        string calldata payeeDisplayName,
        uint256 amount,
        uint64 dueAt,
        uint64 reviewWindowSec,
        bytes32 invoiceRefHash,
        string calldata memo
    ) external returns (uint256 invoiceId) {
        if (payer == address(0)) revert ZeroAddress();
        if (payer == msg.sender) revert SelfInvoice();
        if (amount == 0) revert ZeroAmount();
        bytes memory nameBytes = bytes(payeeDisplayName);
        if (nameBytes.length == 0) revert EmptyDisplayName();
        if (nameBytes.length > MAX_NAME_LEN) revert DisplayNameTooLong();
        if (bytes(memo).length > MAX_MEMO_LEN) revert MemoTooLong();
        if (dueAt <= uint64(block.timestamp)) revert InvalidDueAt();
        if (reviewWindowSec > MAX_REVIEW_WINDOW) revert ReviewWindowTooLong();

        invoiceId = nextInvoiceId++;
        bytes32 nameHash = keccak256(nameBytes);

        _invoices[invoiceId] = Invoice({
            id: invoiceId,
            payee: msg.sender,
            payer: payer,
            payeeDisplayName: payeeDisplayName,
            payeeNameHash: nameHash,
            amount: amount,
            createdAt: uint64(block.timestamp),
            dueAt: dueAt,
            reviewWindowSec: reviewWindowSec,
            confirmedAt: 0,
            paidAt: 0,
            finalizeAfter: 0,
            invoiceRefHash: invoiceRefHash,
            memo: memo,
            status: InvoiceStatus.Issued
        });

        _payeeInvoices[msg.sender].push(invoiceId);
        _payerInvoices[payer].push(invoiceId);

        emit InvoiceCreated(
            invoiceId,
            msg.sender,
            payer,
            payeeDisplayName,
            amount,
            dueAt,
            reviewWindowSec,
            invoiceRefHash
        );
    }

    /// @notice Read-only Confirmation-of-Payee check for UI pre-flight validation.
    function verifyPayee(
        uint256 invoiceId,
        address expectedPayee,
        string calldata expectedDisplayName
    ) external view returns (bool matched, string memory reason) {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) return (false, "INVOICE_NOT_FOUND");
        if (inv.payee != expectedPayee) return (false, "PAYEE_ADDRESS_MISMATCH");
        if (inv.payeeNameHash != keccak256(bytes(expectedDisplayName))) {
            return (false, "PAYEE_NAME_MISMATCH");
        }
        return (true, "MATCH");
    }

    /// @notice Mandatory Confirmation of Payee (CoP) step: payer must confirm exact payee address & display name.
    function confirmPayee(
        uint256 invoiceId,
        address expectedPayee,
        string calldata expectedDisplayName
    ) external {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payer) revert NotPayer();
        if (inv.status != InvoiceStatus.Issued) {
            revert InvalidStatus(InvoiceStatus.Issued, inv.status);
        }
        if (uint64(block.timestamp) > inv.dueAt) revert InvoicePastDue();
        if (expectedPayee != inv.payee) revert PayeeAddressMismatch(inv.payee, expectedPayee);
        if (keccak256(bytes(expectedDisplayName)) != inv.payeeNameHash) revert PayeeNameMismatch();

        uint64 ts = uint64(block.timestamp);
        inv.status = InvoiceStatus.PayeeConfirmed;
        inv.confirmedAt = ts;

        emit PayeeConfirmed(invoiceId, msg.sender, expectedPayee, inv.payeeNameHash, ts);
    }

    /// @notice Pays exact tUSD8 amount into escrow. Strictly requires prior Confirmation of Payee.
    function payInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payer) revert NotPayer();
        if (inv.status != InvoiceStatus.PayeeConfirmed) {
            revert InvalidStatus(InvoiceStatus.PayeeConfirmed, inv.status);
        }
        if (uint64(block.timestamp) > inv.dueAt) revert InvoicePastDue();

        uint64 ts = uint64(block.timestamp);
        uint64 finalizeAt = ts + inv.reviewWindowSec;

        inv.status = InvoiceStatus.PaidInEscrow;
        inv.paidAt = ts;
        inv.finalizeAfter = finalizeAt;
        totalEscrowed += inv.amount;

        if (!token.transferFrom(msg.sender, address(this), inv.amount)) revert TransferFailed();

        emit InvoicePaid(invoiceId, msg.sender, inv.payee, inv.amount, ts, finalizeAt);
    }

    /// @notice Payer acknowledges delivery and immediately releases escrowed tUSD8 to the payee.
    function acknowledgeAndRelease(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payer) revert NotPayer();
        if (inv.status != InvoiceStatus.PaidInEscrow) {
            revert InvalidStatus(InvoiceStatus.PaidInEscrow, inv.status);
        }
        _settle(inv, msg.sender);
    }

    /// @notice Finalizes settlement to the payee once the review window has elapsed.
    function finalizeSettlement(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (inv.status != InvoiceStatus.PaidInEscrow) {
            revert InvalidStatus(InvoiceStatus.PaidInEscrow, inv.status);
        }
        if (uint64(block.timestamp) < inv.finalizeAfter) {
            revert ReviewWindowActive(inv.finalizeAfter);
        }
        _settle(inv, msg.sender);
    }

    /// @notice Payee may voluntarily refund an escrowed payment back to the payer before settlement.
    function refundByPayee(uint256 invoiceId, string calldata reason) external nonReentrant {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payee) revert NotPayee();
        if (inv.status != InvoiceStatus.PaidInEscrow) {
            revert InvalidStatus(InvoiceStatus.PaidInEscrow, inv.status);
        }

        uint256 amount = inv.amount;
        inv.status = InvoiceStatus.Refunded;
        totalEscrowed -= amount;

        if (!token.transfer(inv.payer, amount)) revert TransferFailed();

        emit InvoiceRefunded(invoiceId, inv.payee, inv.payer, amount, reason);
    }

    /// @notice Payee cancels an unpaid invoice (Issued or PayeeConfirmed).
    function cancelInvoice(uint256 invoiceId) external {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payee) revert NotPayee();
        if (inv.status != InvoiceStatus.Issued && inv.status != InvoiceStatus.PayeeConfirmed) {
            revert InvalidStatus(InvoiceStatus.Issued, inv.status);
        }

        inv.status = InvoiceStatus.Cancelled;
        emit InvoiceCancelled(invoiceId, msg.sender, uint64(block.timestamp));
    }

    /// @notice Marks an unpaid invoice Expired once block.timestamp > dueAt.
    function expireInvoice(uint256 invoiceId) external {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.id == 0) revert InvoiceNotFound();
        if (msg.sender != inv.payer && msg.sender != inv.payee) revert NotParty();
        if (inv.status != InvoiceStatus.Issued && inv.status != InvoiceStatus.PayeeConfirmed) {
            revert InvalidStatus(InvoiceStatus.Issued, inv.status);
        }
        if (uint64(block.timestamp) <= inv.dueAt) revert InvoiceNotYetPastDue();

        inv.status = InvoiceStatus.Expired;
        emit InvoiceExpired(invoiceId, msg.sender, uint64(block.timestamp));
    }

    function _settle(Invoice storage inv, address releaser) internal {
        uint256 amount = inv.amount;
        inv.status = InvoiceStatus.Settled;
        totalEscrowed -= amount;
        totalSettled += amount;

        if (!token.transfer(inv.payee, amount)) revert TransferFailed();

        emit InvoiceSettled(inv.id, inv.payee, amount, releaser, uint64(block.timestamp));
    }

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return _invoices[invoiceId];
    }

    function getPayeeInvoiceIds(address payee) external view returns (uint256[] memory) {
        return _payeeInvoices[payee];
    }

    function getPayerInvoiceIds(address payer) external view returns (uint256[] memory) {
        return _payerInvoices[payer];
    }
}
