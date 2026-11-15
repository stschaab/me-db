// Next2You presence: every visible page reports activity once a minute (n2y_heartbeat);
// closing the tab/window marks the user offline (n2y_offline) so their pin disappears.
function n2yPresence(db, supabaseUrl, anonKey) {
  let token = null;
  let lastClick = 0;
  db.auth.getSession().then(({ data }) => { token = data.session?.access_token || null; });
  db.auth.onAuthStateChange((_event, session) => { token = session?.access_token || null; });

  const beat = () => {
    if (document.visibilityState === 'visible') db.rpc('n2y_heartbeat').then(() => {});
  };
  beat();
  setInterval(beat, 60000);
  document.addEventListener('visibilitychange', beat);

  // A click right before pagehide is almost always in-app navigation (map → chat …), not closing the tab.
  document.addEventListener('click', () => { lastClick = Date.now(); }, true);
  window.addEventListener('pagehide', () => {
    if (!token || Date.now() - lastClick < 3000) return;
    fetch(supabaseUrl + '/rest/v1/rpc/n2y_offline', {
      method: 'POST',
      keepalive: true,
      headers: { apikey: anonKey, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: '{}'
    }).catch(() => {});
  });
}

// AI test personas carry the suffix "(KI)"; the DB strips it from real users' nicknames (n2y_guard_ai_nickname)
function n2yIsAI(nickname) { return /\(KI\)\s*$/.test(nickname || ''); }
const N2Y_AI_HINT = '🤖 KI-Testperson – antwortet automatisch';

function n2yIdleLabel(min) {
  if (min < 60) return min + ' min';
  const h = Math.floor(min / 60), m = min % 60;
  return h + 'h' + (m ? m + 'min' : '');
}

// Last activity derived from inactive_min (minute precision); short form for lists
function n2yLastSeenLabel(min, short = false) {
  const d = new Date(Date.now() - min * 60000), now = new Date();
  const yest = new Date(now); yest.setDate(now.getDate() - 1);
  const time = d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' });
  if (d.toDateString() === now.toDateString()) return short ? time : 'heute ' + time;
  if (d.toDateString() === yest.toDateString()) return short ? 'gestern' : 'gestern ' + time;
  const date = d.toLocaleDateString('de-DE', { day: 'numeric', month: 'short' });
  return short ? date : date + ', ' + time;
}

// p = row of n2y_partner_presence(); null when the partner hides their status
function n2yStatus(p) {
  if (!p || p.status === 'hidden') return null;
  if (p.status === 'active') return { cls: 'active', text: '🟢 aktiv' };
  if (p.status === 'idle') return { cls: 'idle', text: '💤 seit ' + n2yIdleLabel(p.inactive_min) + ' inaktiv' };
  return { cls: 'offline', text: '⚫ offline · zuletzt ' + n2yLastSeenLabel(p.inactive_min) };
}
