// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MockTUSD8 } from "../src/MockTUSD8.sol";
import { ClearbillRegistry } from "../src/ClearbillRegistry.sol";
import { ClearbillInvoices } from "../src/ClearbillInvoices.sol";

contract ClearbillTest is Test {
    MockTUSD8 internal tusd8;
    ClearbillRegistry internal registry;
    ClearbillInvoices internal invoices;

    address internal merchant = makeAddr("merchant");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");

    string internal constant MERCHANT_NAME = "Northstar Design Studio LLC";
    uint256 internal constant INVOICE_AMOUNT = 250_500_000; // 250.500000 tUSD8 (6 decimals)

    function setUp() public {
        vm.warp(1_764_000_000);
        tusd8 = new MockTUSD8();
        registry = new ClearbillRegistry();
        invoices = new ClearbillInvoices(address(tusd8));

        tusd8.mint(payer, 5_000_000_000); // 5,000.000000 tUSD8
        vm.prank(payer);
        tusd8.approve(address(invoices), type(uint256).max);
    }

    function _createSampleInvoice(uint64 reviewWindow) internal returns (uint256 id) {
        uint64 dueAt = uint64(vm.getBlockTimestamp() + 3 days);
        vm.prank(merchant);
        id = invoices.createInvoice(
            payer,
            MERCHANT_NAME,
            INVOICE_AMOUNT,
            dueAt,
            reviewWindow,
            keccak256("INV-2026-0042"),
            "Q4 brand sprint deliverable"
        );
    }

    function test_HappyPath_CoPAndImmediateAcknowledgeRelease() public {
        uint256 id = _createSampleInvoice(2 days);

        // Pre-flight CoP check matches
        (bool matched, string memory reason) = invoices.verifyPayee(id, merchant, MERCHANT_NAME);
        assertTrue(matched);
        assertEq(reason, "MATCH");

        // 1. Confirm Payee
        vm.prank(payer);
        invoices.confirmPayee(id, merchant, MERCHANT_NAME);

        // 2. Pay exact 6-decimal tUSD8 into escrow
        uint256 payerBefore = tusd8.balanceOf(payer);
        vm.prank(payer);
        invoices.payInvoice(id);
        assertEq(payerBefore - tusd8.balanceOf(payer), INVOICE_AMOUNT);
        assertEq(tusd8.balanceOf(address(invoices)), INVOICE_AMOUNT);
        assertEq(invoices.totalEscrowed(), INVOICE_AMOUNT);

        // 3. Payer acknowledges and releases immediately
        vm.prank(payer);
        invoices.acknowledgeAndRelease(id);

        assertEq(tusd8.balanceOf(merchant), INVOICE_AMOUNT);
        assertEq(tusd8.balanceOf(address(invoices)), 0);
        assertEq(invoices.totalEscrowed(), 0);
        assertEq(invoices.totalSettled(), INVOICE_AMOUNT);

        ClearbillInvoices.Invoice memory inv = invoices.getInvoice(id);
        assertEq(uint8(inv.status), uint8(ClearbillInvoices.InvoiceStatus.Settled));
    }

    function test_AutoFinalizeAfterReviewWindow() public {
        uint256 id = _createSampleInvoice(1 days);

        vm.startPrank(payer);
        invoices.confirmPayee(id, merchant, MERCHANT_NAME);
        invoices.payInvoice(id);
        vm.stopPrank();

        ClearbillInvoices.Invoice memory inv = invoices.getInvoice(id);

        // Early finalize reverts
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ClearbillInvoices.ReviewWindowActive.selector, inv.finalizeAfter)
        );
        invoices.finalizeSettlement(id);

        // After review window elapses, anyone can trigger settlement to payee
        vm.warp(inv.finalizeAfter);
        vm.prank(stranger);
        invoices.finalizeSettlement(id);

        assertEq(tusd8.balanceOf(merchant), INVOICE_AMOUNT);
        assertEq(uint8(invoices.getInvoice(id).status), uint8(ClearbillInvoices.InvoiceStatus.Settled));
    }

    function test_CannotPayWithoutConfirmationOfPayee() public {
        uint256 id = _createSampleInvoice(1 days);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearbillInvoices.InvalidStatus.selector,
                ClearbillInvoices.InvoiceStatus.PayeeConfirmed,
                ClearbillInvoices.InvoiceStatus.Issued
            )
        );
        invoices.payInvoice(id);
    }

    function test_CoPMismatchAbortsPayment() public {
        uint256 id = _createSampleInvoice(1 days);

        // Wrong payee address
        (bool m1, string memory r1) = invoices.verifyPayee(id, stranger, MERCHANT_NAME);
        assertFalse(m1);
        assertEq(r1, "PAYEE_ADDRESS_MISMATCH");

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearbillInvoices.PayeeAddressMismatch.selector,
                merchant,
                stranger
            )
        );
        invoices.confirmPayee(id, stranger, MERCHANT_NAME);

        // Wrong display name (typosquatting / lookalike protection)
        (bool m2, string memory r2) = invoices.verifyPayee(id, merchant, "Northstar Design Studio Inc");
        assertFalse(m2);
        assertEq(r2, "PAYEE_NAME_MISMATCH");

        vm.prank(payer);
        vm.expectRevert(ClearbillInvoices.PayeeNameMismatch.selector);
        invoices.confirmPayee(id, merchant, "Northstar Design Studio Inc");
    }

    function test_PayeeVoluntaryRefundAndNoDoubleSettle() public {
        uint256 id = _createSampleInvoice(2 days);

        vm.startPrank(payer);
        invoices.confirmPayee(id, merchant, MERCHANT_NAME);
        invoices.payInvoice(id);
        vm.stopPrank();

        uint256 payerAfterPay = tusd8.balanceOf(payer);

        vm.prank(merchant);
        invoices.refundByPayee(id, "Duplicate billing");

        assertEq(tusd8.balanceOf(payer) - payerAfterPay, INVOICE_AMOUNT);
        assertEq(invoices.totalEscrowed(), 0);
        assertEq(uint8(invoices.getInvoice(id).status), uint8(ClearbillInvoices.InvoiceStatus.Refunded));

        // Cannot settle after refund
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearbillInvoices.InvalidStatus.selector,
                ClearbillInvoices.InvoiceStatus.PaidInEscrow,
                ClearbillInvoices.InvoiceStatus.Refunded
            )
        );
        invoices.finalizeSettlement(id);
    }

    function test_ExpiryAndCancellationGuards() public {
        uint256 id1 = _createSampleInvoice(1 days);
        uint256 id2 = _createSampleInvoice(1 days);

        // Payee cancels id1 before payment
        vm.prank(merchant);
        invoices.cancelInvoice(id1);
        assertEq(uint8(invoices.getInvoice(id1).status), uint8(ClearbillInvoices.InvoiceStatus.Cancelled));

        // Past due id2 cannot be confirmed or paid, and expires cleanly
        uint64 dueAt = invoices.getInvoice(id2).dueAt;
        vm.warp(dueAt + 1);

        vm.prank(payer);
        vm.expectRevert(ClearbillInvoices.InvoicePastDue.selector);
        invoices.confirmPayee(id2, merchant, MERCHANT_NAME);

        vm.prank(payer);
        invoices.expireInvoice(id2);
        assertEq(uint8(invoices.getInvoice(id2).status), uint8(ClearbillInvoices.InvoiceStatus.Expired));
    }

    function test_StrictRoleAuth() public {
        uint256 id = _createSampleInvoice(1 days);

        vm.prank(stranger);
        vm.expectRevert(ClearbillInvoices.NotPayer.selector);
        invoices.confirmPayee(id, merchant, MERCHANT_NAME);

        vm.prank(stranger);
        vm.expectRevert(ClearbillInvoices.NotPayee.selector);
        invoices.cancelInvoice(id);

        vm.prank(payer);
        invoices.confirmPayee(id, merchant, MERCHANT_NAME);

        vm.prank(stranger);
        vm.expectRevert(ClearbillInvoices.NotPayer.selector);
        invoices.payInvoice(id);

        vm.prank(payer);
        invoices.payInvoice(id);

        vm.prank(stranger);
        vm.expectRevert(ClearbillInvoices.NotPayer.selector);
        invoices.acknowledgeAndRelease(id);

        vm.prank(stranger);
        vm.expectRevert(ClearbillInvoices.NotPayee.selector);
        invoices.refundByPayee(id, "nope");
    }

    function test_ValidationAndSixDecimalEdgeCases() public {
        uint64 futureDue = uint64(vm.getBlockTimestamp() + 1 days);

        vm.startPrank(merchant);
        vm.expectRevert(ClearbillInvoices.ZeroAddress.selector);
        invoices.createInvoice(address(0), MERCHANT_NAME, 1, futureDue, 0, bytes32(0), "");

        vm.expectRevert(ClearbillInvoices.SelfInvoice.selector);
        invoices.createInvoice(merchant, MERCHANT_NAME, 1, futureDue, 0, bytes32(0), "");

        vm.expectRevert(ClearbillInvoices.ZeroAmount.selector);
        invoices.createInvoice(payer, MERCHANT_NAME, 0, futureDue, 0, bytes32(0), "");

        vm.expectRevert(ClearbillInvoices.EmptyDisplayName.selector);
        invoices.createInvoice(payer, "", 1, futureDue, 0, bytes32(0), "");

        vm.expectRevert(ClearbillInvoices.InvalidDueAt.selector);
        invoices.createInvoice(payer, MERCHANT_NAME, 1, uint64(vm.getBlockTimestamp()), 0, bytes32(0), "");

        vm.expectRevert(ClearbillInvoices.ReviewWindowTooLong.selector);
        invoices.createInvoice(payer, MERCHANT_NAME, 1, futureDue, 15 days, bytes32(0), "");

        // 1 base unit = $0.000001 tUSD8 with 0s review window works cleanly
        uint256 microId = invoices.createInvoice(payer, MERCHANT_NAME, 1, futureDue, 0, bytes32(0), "micro");
        vm.stopPrank();

        vm.startPrank(payer);
        invoices.confirmPayee(microId, merchant, MERCHANT_NAME);
        invoices.payInvoice(microId);
        vm.stopPrank();

        invoices.finalizeSettlement(microId);
        assertEq(tusd8.balanceOf(merchant), 1);
    }

    function test_PayeeRegistryRegistrationAndMatch() public {
        vm.prank(merchant);
        registry.registerProfile(MERCHANT_NAME, "Design & Dev");

        assertTrue(registry.matchesRegisteredName(merchant, MERCHANT_NAME));
        assertFalse(registry.matchesRegisteredName(merchant, "Other Studio"));
        assertFalse(registry.matchesRegisteredName(stranger, MERCHANT_NAME));

        ClearbillRegistry.PayeeProfile memory p = registry.getProfile(merchant);
        assertTrue(p.registered);
        assertEq(p.displayName, MERCHANT_NAME);
        assertEq(p.businessTag, "Design & Dev");
    }
}
