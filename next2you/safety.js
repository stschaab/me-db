// Next2You safety tools shared by map and chat: report dialog (n2y_report), block / unblock.
// Reports are stored with a snapshot of the conversation; the operator reviews them in n2y_admin.reports.
(function () {
  const css = `
  .n2y-modal-bg { position: fixed; inset: 0; background: rgba(10,15,30,0.55); z-index: 3000; display: flex; align-items: flex-end; justify-content: center; }
  @media (min-width: 560px) { .n2y-modal-bg { align-items: center; } }
  .n2y-modal { background: white; width: 100%; max-width: 440px; border-radius: 18px 18px 0 0; padding: 20px 20px max(20px, env(safe-area-inset-bottom));
    max-height: 92vh; overflow-y: auto; font-family: inherit; color: #1a1a2e; box-shadow: 0 -4px 30px rgba(0,0,0,0.25); }
  @media (min-width: 560px) { .n2y-modal { border-radius: 18px; } }
  .n2y-modal h3 { font-size: 1.05rem; margin-bottom: 4px; }
  .n2y-modal .sub { font-size: 0.8rem; color: #777; margin-bottom: 14px; line-height: 1.4; }
  .n2y-modal .reasons label { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border: 1.5px solid #e6e9ee; border-radius: 10px;
    margin-bottom: 7px; font-size: 0.9rem; cursor: pointer; }
  .n2y-modal .reasons label:has(input:checked) { border-color: #e05a5f; background: #fdf0f0; }
  .n2y-modal .reasons input { accent-color: #e05a5f; width: 17px; height: 17px; margin: 0; }
  .n2y-modal textarea { width: 100%; min-height: 70px; padding: 10px 12px; border: 1.5px solid #e0e0e0; border-radius: 10px; font: inherit; font-size: 16px;
    resize: vertical; margin-top: 6px; outline: none; }
  .n2y-modal textarea:focus { border-color: #00b4d8; }
  .n2y-modal .blk { display: flex; align-items: center; gap: 9px; font-size: 0.88rem; margin: 12px 0 4px; cursor: pointer; }
  .n2y-modal .blk input { width: 17px; height: 17px; accent-color: #00b4d8; margin: 0; }
  .n2y-modal .note { font-size: 0.72rem; color: #999; margin-top: 8px; line-height: 1.4; }
  .n2y-modal .btns { display: flex; gap: 10px; margin-top: 16px; }
  .n2y-modal .btns button { flex: 1; padding: 13px; border-radius: 11px; border: none; font-size: 0.95rem; font-weight: 700; cursor: pointer; font-family: inherit; }
  .n2y-modal .b-cancel { background: #eef1f5; color: #444; }
  .n2y-modal .b-send { background: #e05a5f; color: white; }
  .n2y-modal .b-send:disabled { background: #f0b4b6; cursor: not-allowed; }
  .n2y-toast { position: fixed; left: 50%; top: 84px; transform: translateX(-50%); background: #1a1a2e; color: white; padding: 11px 18px; border-radius: 12px;
    font-size: 0.88rem; z-index: 3100; box-shadow: 0 4px 18px rgba(0,0,0,0.3); max-width: calc(100% - 32px); text-align: center; }`;
  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);
})();

const N2Y_REPORT_REASONS = [
  ['harassment', 'Belästigung oder Beleidigung'],
  ['threat', 'Bedrohung oder Gewalt'],
  ['illegal', 'Illegale Aktivitäten (z. B. Drogen, Waffen, Betrug)'],
  ['spam', 'Spam, Werbung oder Fake-Profil'],
  ['minor', 'Person wirkt minderjährig (unter 16)'],
  ['other', 'Etwas anderes'],
];

function n2yEsc(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function n2yToast(text, ms = 3200) {
  document.querySelector('.n2y-toast')?.remove();
  const t = document.createElement('div');
  t.className = 'n2y-toast';
  t.textContent = text;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

// opts: { userId, nickname, conversationId?, onBlocked?() }
function n2yOpenReport(db, opts) {
  document.querySelector('.n2y-modal-bg')?.remove();
  const name = opts.nickname || 'Anonym';
  const bg = document.createElement('div');
  bg.className = 'n2y-modal-bg';
  bg.innerHTML = `<div class="n2y-modal" role="dialog" aria-modal="true" aria-label="Melden">
    <h3>🚩 ${n2yEsc(name)} melden</h3>
    <div class="sub">Was ist passiert? Deine Meldung ist vertraulich – ${n2yEsc(name)} erfährt nicht, wer gemeldet hat.</div>
    <div class="reasons">${N2Y_REPORT_REASONS.map(([v, l]) =>
      `<label><input type="radio" name="n2yReason" value="${v}"> ${n2yEsc(l)}</label>`).join('')}</div>
    <textarea id="n2yReportDetails" maxlength="1000" placeholder="Details (optional)"></textarea>
    <label class="blk"><input type="checkbox" id="n2yReportBlock" checked> ${n2yEsc(name)} zusätzlich blockieren</label>
    <div class="note">${opts.conversationId ? 'Der bisherige Chatverlauf wird mit der Meldung gesichert. ' : ''}Bei akuter Gefahr ruf bitte sofort die Polizei: 110.</div>
    <div class="btns"><button class="b-cancel" id="n2yReportCancel">Abbrechen</button>
      <button class="b-send" id="n2yReportSend" disabled>Melden</button></div>
  </div>`;
  document.body.appendChild(bg);
  const send = bg.querySelector('#n2yReportSend');
  bg.querySelectorAll('input[name="n2yReason"]').forEach(r => r.addEventListener('change', () => { send.disabled = false; }));
  const close = () => bg.remove();
  bg.addEventListener('click', (e) => { if (e.target === bg) close(); });
  bg.querySelector('#n2yReportCancel').onclick = close;
  send.onclick = async () => {
    const reason = bg.querySelector('input[name="n2yReason"]:checked')?.value;
    if (!reason) return;
    send.disabled = true;
    send.textContent = '…';
    const { error } = await db.rpc('n2y_report', {
      p_reported: opts.userId, p_conversation: opts.conversationId || null,
      p_reason: reason, p_details: bg.querySelector('#n2yReportDetails').value });
    if (error) {
      send.disabled = false; send.textContent = 'Melden';
      alert(/too many/.test(error.message) ? 'Du hast heute schon sehr viele Meldungen gesendet. Bitte versuch es morgen wieder.'
                                           : 'Meldung konnte nicht gesendet werden: ' + error.message);
      return;
    }
    let blocked = false;
    if (bg.querySelector('#n2yReportBlock').checked) {
      blocked = !(await db.rpc('n2y_block_user', { p_user: opts.userId })).error;
    }
    close();
    n2yToast('Danke! Deine Meldung ist eingegangen' + (blocked ? ' und ' + name + ' ist blockiert.' : '.'));
    if (blocked && opts.onBlocked) opts.onBlocked();
  };
}

async function n2yBlock(db, userId, nickname) {
  const name = nickname || 'Anonym';
  if (!confirm(name + ' blockieren?\n\nIhr könnt euch dann keine Nachrichten mehr schreiben und seht euch nicht mehr auf der Karte. ' +
               name + ' wird nicht benachrichtigt. Entsperren geht jederzeit in den Einstellungen.')) return false;
  const { error } = await db.rpc('n2y_block_user', { p_user: userId });
  if (error) { alert('Fehler: ' + error.message); return false; }
  n2yToast(name + ' ist blockiert.');
  return true;
}

async function n2yUnblock(db, userId, nickname) {
  const { error } = await db.rpc('n2y_unblock_user', { p_user: userId });
  if (error) { alert('Fehler: ' + error.message); return false; }
  n2yToast((nickname || 'Anonym') + ' ist nicht mehr blockiert.');
  return true;
}

async function n2yMyBlockedIds(db) {
  const { data } = await db.rpc('n2y_my_blocks');
  return new Set((data || []).map(b => b.user_id));
}
