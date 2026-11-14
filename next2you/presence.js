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

function n2yIdleLabel(min) {
  if (min < 60) return min + ' min';
  const h = Math.floor(min / 60), m = min % 60;
  return h + 'h' + (m ? m + 'min' : '');
}

// p = row of n2y_partner_presence(); null when the partner hides their status
function n2yStatus(p) {
  if (!p || p.status === 'hidden') return null;
  if (p.status === 'active') return { cls: 'active', text: '🟢 aktiv' };
  if (p.status === 'idle') return { cls: 'idle', text: '💤 seit ' + n2yIdleLabel(p.inactive_min) + ' inaktiv' };
  return { cls: 'offline', text: '⚫ offline' };
}
