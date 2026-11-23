(() => {
  const AEVUM_RPC = "https://rpc-test.qday.info";
  const AEVUM_CHAIN_ID = 44005;
  const OFFICIAL_TUSD8 = "0x456569838f1d43009A91ebA4263147Afd7233483";

  const state = {
    nextId: 1,
    invoices: [],
  };

  const $ = (id) => document.getElementById(id);
  const statusBanner = $("statusBanner");
  const rpcBadge = $("rpcBadge");
  const invoiceList = $("invoiceList");
  const copResult = $("copResult");
  const castPreview = $("castPreview");

  function setBanner(msg, kind = "") {
    statusBanner.textContent = msg;
    statusBanner.className = "status-banner" + (kind ? ` ${kind}` : "");
  }

  function isHexAddress(v) {
    return /^0x[0-9a-fA-F]{40}$/.test(v.trim());
  }

  function toBaseUnits(amountStr) {
    const n = Number(amountStr);
    if (!Number.isFinite(n) || n <= 0) return null;
    return Math.round(n * 1_000_000);
  }

  function formatTusd8(units) {
    return (units / 1_000_000).toFixed(6) + " tUSD8";
  }

  async function checkAevumRpc() {
    rpcBadge.textContent = "RPC: checking…";
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 3500);
      const res = await fetch(AEVUM_RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
        signal: controller.signal,
      });
      clearTimeout(timer);
      const data = await res.json();
      const cid = parseInt(data.result, 16);
      if (cid === AEVUM_CHAIN_ID) {
        rpcBadge.textContent = `RPC: Aevum (${cid})`;
        rpcBadge.className = "badge ok";
        setBanner("Connected read-only to QDay Aevum Testnet (44005). Ready for Confirmation-of-Payee invoice flow.", "success");
      } else {
        rpcBadge.textContent = `RPC: wrong chain (${cid})`;
        rpcBadge.className = "badge err";
        setBanner(`Safety halt: RPC returned chain ID ${cid}, expected Aevum Testnet (44005).`, "error");
      }
    } catch {
      rpcBadge.textContent = "RPC: offline / local demo";
      rpcBadge.className = "badge warn";
      setBanner("Local interactive demo mode active (Aevum RPC unreachable from this browser context). All CoP validation rules mirror ClearbillInvoices.sol.", "");
    }
  }

  function renderInvoices() {
    if (state.invoices.length === 0) {
      invoiceList.innerHTML = `<div class="muted">No invoices yet. Issue a tUSD8 invoice on the left or click <strong>Load Sample</strong> to walk through the Confirmation-of-Payee flow.</div>`;
      return;
    }

    invoiceList.innerHTML = state.invoices
      .map((inv) => {
        const badgeClass =
          inv.status === "Settled"
            ? "ok"
            : inv.status === "PayeeConfirmed" || inv.status === "PaidInEscrow"
            ? "warn"
            : "";
        return `
          <div class="invoice-item" data-invoice-id="${inv.id}">
            <div class="invoice-head">
              <strong>Invoice #${inv.id} — ${escapeHtml(inv.payeeName)}</strong>
              <span class="badge ${badgeClass}">${inv.status}</span>
            </div>
            <div class="muted" style="margin-top:4px;">
              Amount: <code>${formatTusd8(inv.amountUnits)}</code> (${inv.amountUnits} units) ·
              Payee: <code>${inv.payee}</code> ·
              Payer: <code>${inv.payer}</code>
            </div>
            <div class="muted">Memo: ${escapeHtml(inv.memo || "—")}</div>
          </div>
        `;
      })
      .join("");

    const latest = state.invoices[state.invoices.length - 1];
    castPreview.textContent = [
      `# Read-only Aevum Testnet (44005) command template for Invoice #${latest.id}`,
      `# Official tUSD8: ${OFFICIAL_TUSD8}`,
      `cast call $CLEARBILL_INVOICES "verifyPayee(uint256,address,string)(bool,string)" ${latest.id} ${latest.payee} "${latest.payeeName}" --rpc-url ${AEVUM_RPC}`,
      `cast send $CLEARBILL_INVOICES "confirmPayee(uint256,address,string)" ${latest.id} ${latest.payee} "${latest.payeeName}" --rpc-url ${AEVUM_RPC} --private-key $TESTNET_PK`,
      `cast send ${OFFICIAL_TUSD8} "approve(address,uint256)" $CLEARBILL_INVOICES ${latest.amountUnits} --rpc-url ${AEVUM_RPC} --private-key $TESTNET_PK`,
      `cast send $CLEARBILL_INVOICES "payInvoice(uint256)" ${latest.id} --rpc-url ${AEVUM_RPC} --private-key $TESTNET_PK`,
      `cast send $CLEARBILL_INVOICES "acknowledgeAndRelease(uint256)" ${latest.id} --rpc-url ${AEVUM_RPC} --private-key $TESTNET_PK`,
    ].join("\n");
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  $("createForm").addEventListener("submit", (e) => {
    e.preventDefault();
    const payeeName = $("payeeName").value.trim();
    const payee = $("payeeAddr").value.trim();
    const payer = $("payerAddr").value.trim();
    const amountUnits = toBaseUnits($("amount").value);
    const memo = $("memo").value.trim();

    if (!payeeName) return setBanner("Error: Payee Display Name is required.", "error");
    if (!isHexAddress(payee) || !isHexAddress(payer)) {
      return setBanner("Error: Payee and Payer must be valid 0x EVM addresses.", "error");
    }
    if (payee.toLowerCase() === payer.toLowerCase()) {
      return setBanner("Error: Payee and Payer cannot be the same address (SelfInvoice).", "error");
    }
    if (!amountUnits) return setBanner("Error: Amount must be > 0 tUSD8.", "error");

    const inv = {
      id: state.nextId++,
      payeeName,
      payee,
      payer,
      amountUnits,
      memo,
      status: "Issued",
    };
    state.invoices.push(inv);
    $("copInvoiceId").value = String(inv.id);
    $("copExpectedAddr").value = inv.payee;
    $("copExpectedName").value = inv.payeeName;

    setBanner(`Invoice #${inv.id} issued for ${formatTusd8(inv.amountUnits)}. Next: complete Confirmation of Payee before paying.`, "success");
    renderInvoices();
  });

  $("loadSampleBtn").addEventListener("click", () => {
    $("payeeName").value = "Northstar Design Studio LLC";
    $("payeeAddr").value = "0x1111111111111111111111111111111111111111";
    $("payerAddr").value = "0x2222222222222222222222222222222222222222";
    $("amount").value = "250.50";
    $("memo").value = "Q4 brand sprint deliverable";
    setBanner("Sample invoice prefilled. Submit to issue it.", "");
  });

  $("verifyCopBtn").addEventListener("click", () => {
    const id = Number($("copInvoiceId").value);
    const inv = state.invoices.find((x) => x.id === id);
    if (!inv) {
      copResult.textContent = "INVOICE_NOT_FOUND";
      return setBanner(`Error: Invoice #${id || "?"} not found.`, "error");
    }
    if (inv.status !== "Issued") {
      copResult.textContent = `InvalidStatus (${inv.status})`;
      return setBanner(`Error: Invoice #${id} is already in status ${inv.status}.`, "error");
    }
    const expAddr = $("copExpectedAddr").value.trim();
    const expName = $("copExpectedName").value.trim();
    if (expAddr.toLowerCase() !== inv.payee.toLowerCase()) {
      copResult.textContent = "BLOCKED: PAYEE_ADDRESS_MISMATCH";
      return setBanner("Confirmation of Payee FAILED: Payee address mismatch. Payment remains locked.", "error");
    }
    if (expName !== inv.payeeName) {
      copResult.textContent = "BLOCKED: PAYEE_NAME_MISMATCH";
      return setBanner("Confirmation of Payee FAILED: Payee display name mismatch. Payment remains locked.", "error");
    }

    inv.status = "PayeeConfirmed";
    copResult.textContent = "MATCH: PayeeConfirmed — tUSD8 payment unlocked.";
    setBanner(`Invoice #${id} passed Confirmation of Payee! You may now pay tUSD8 into escrow.`, "success");
    renderInvoices();
  });

  $("payBtn").addEventListener("click", () => {
    const id = Number($("copInvoiceId").value);
    const inv = state.invoices.find((x) => x.id === id);
    if (!inv) return setBanner(`Error: Invoice #${id || "?"} not found.`, "error");
    if (inv.status !== "PayeeConfirmed") {
      if (inv.status === "Issued") {
        $("copResult").className = "cop-result cop-err";
        $("copResult").textContent = "BLOCKED: Confirm Payee (CoP) first";
      }
      return setBanner(`Blocked: Invoice #${id} must be PayeeConfirmed before tUSD8 can move (current: ${inv.status}).`, "error");
    }
    inv.status = "PaidInEscrow";
    setBanner(`Invoice #${id} paid (${formatTusd8(inv.amountUnits)}) into escrow.`, "success");
    renderInvoices();
  });

  $("releaseBtn").addEventListener("click", () => {
    const id = Number($("copInvoiceId").value);
    const inv = state.invoices.find((x) => x.id === id);
    if (!inv) return setBanner(`Error: Invoice #${id || "?"} not found.`, "error");
    if (inv.status !== "PaidInEscrow") {
      return setBanner(`Error: Invoice #${id} is not in PaidInEscrow (current: ${inv.status}).`, "error");
    }
    inv.status = "Settled";
    setBanner(`Invoice #${id} acknowledged and settled (${formatTusd8(inv.amountUnits)}) to ${inv.payeeName}.`, "success");
    renderInvoices();
  });

  $("clearBtn").addEventListener("click", () => {
    state.invoices = [];
    state.nextId = 1;
    copResult.textContent = "";
    castPreview.textContent = "# Create an invoice above to generate the matching Aevum Testnet (44005) cast commands.";
    setBanner("Local demo cleared.", "");
    renderInvoices();
  });

  renderInvoices();
  checkAevumRpc();
})();
