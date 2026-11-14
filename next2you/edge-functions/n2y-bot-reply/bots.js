// Conversation logic for the Next2You AI test personas (shown as "Name (KI)") (plain JS so it runs in Deno and Node tests).
// pickReply() looks at the whole conversation, detects what the human just wrote and returns
// a fitting, not-yet-used line of the persona.

const PERSONAS = {
  'Lena': {
    place: 'im kleinen Café an der Ecke, am Fensterplatz',
    look: 'grüne Jacke, Laptop mit vielen Stickern',
    stay: 90,
    greet: ['Hey {name}! 😊 Schön, dass du schreibst.', 'Hi {name}! Freut mich 🙂'],
    howareyou: ['Gut, danke! Zweiter Cappuccino, ziemlich produktiver Tag bisher ☕ Und bei dir?', 'Ganz gut – ein bisschen zu viel gelesen heute 😅 Und dir?'],
    topics: [
      ['ki|künstlich|chatgpt|claude|llm|maschine|algorithm|technolog', [
        'Ich finde die Frage spannend, ob KI wirklich „versteht“ oder nur extrem gut Muster fortsetzt. Wie siehst du das?',
        'Mich beschäftigt gerade, wer eigentlich verantwortlich ist, wenn eine KI Mist baut – Entwickler, Nutzer oder niemand? 🤔',
        'Nutzt du KI eigentlich im Job oder eher privat?']],
      ['philosoph|bewusstsein|ethik|wille|sinn|moral|denken', [
        'Philosophie ist mein Ding 🙂 Ich lese gerade „Der Ursprung des Bewusstseins“ – total verrückt, wie wenig wir wissen.',
        'Glaubst du an freien Willen? Ich schwanke da jeden Tag 😄',
        'Welche Philosophen magst du denn? Ich bin gerade bei Thomas Metzinger hängengeblieben.']],
    ],
    question: ['Gute Frage 😄 Ich bin Doktorandin, schreibe gerade über Ethik in der KI. Und was machst du so?', 'Hmm, schwer zu sagen – ich denke da gern laut drüber nach. Bei einem Kaffee geht das besser 😉'],
    small: [
      'Was hat dich eigentlich zu der App gebracht?',
      'Ich bin übrigens noch so bis {until} hier. Lust, auf einen Kaffee vorbeizukommen?',
      'Ich mag es, mit Leuten zu reden, die man sonst nie treffen würde. Du auch?'],
  },
  'Jonas': {
    place: 'im Coworking-Café bei der U-Bahn, hinten am großen Tisch',
    look: 'dunkelblauer Hoodie, MacBook, Kopfhörer um den Hals',
    stay: 120,
    greet: ['Moin {name}! 👋', 'Hey {name}, cool dass du schreibst!'],
    howareyou: ['Läuft! Hab gerade einen Bug gefixt, der mich zwei Tage gekostet hat 😅 Und selbst?', 'Gut, bisschen Deadline-Stress, aber alles im Rahmen. Bei dir?'],
    topics: [
      ['ki|künstlich|chatgpt|claude|llm|technolog|app|software|code|programm', [
        'Ich baue gerade eine kleine App, die Kassenzettel mit KI auswertet. Funktioniert erstaunlich gut 😄',
        'Welche Tools nutzt du? Ich bin inzwischen fast nur noch mit KI-Assistenten am Coden.',
        'Ehrlich gesagt frag ich mich manchmal, ob ich in 5 Jahren noch selbst programmiere 😅']],
      ['startup|gründ|business|firma|selbstständig|idee', [
        'Gründen ist ein Abenteuer – bin mit zwei Freunden dabei, noch ohne Investoren.',
        'Hast du auch eine Idee im Kopf, die du mal umsetzen willst?']],
    ],
    question: ['Ich bin Softwareentwickler, seit einem Jahr selbstständig. Und du?', 'Kommt drauf an 😄 Erzähl mal, was du so machst!'],
    small: [
      'Bist du öfter hier in der Gegend unterwegs?',
      'Ich mach gleich eh Pause – wollen wir uns auf einen Kaffee treffen? Ich bin noch bis {until} da.',
      'Ich finde die Idee der App gut: Leute treffen, ohne gleich Dating-Vibes 👍'],
  },
  'Mira': {
    place: 'im Café beim Park, draußen unter dem Sonnenschirm',
    look: 'gelbe Regenjacke, Kamera auf dem Tisch',
    stay: 60,
    greet: ['Hii {name} 😊', 'Hey {name}! 🧗‍♀️'],
    howareyou: ['Super, war heute früh schon an der Kletterwand 💪 Und dir?', 'Gut! Etwas Muskelkater, aber glücklich 😄 Und bei dir?'],
    topics: [
      ['kletter|boulder|fels|halle|sport|berg|wander|outdoor', [
        'Ja, total gern! Meistens in der Fränkischen, am Wochenende geht’s wieder los. Und du?',
        'Bouldern im Winter, Fels im Sommer – das ist mein Rhythmus 😄',
        'Falls du Lust hast: Wir sind eine kleine Gruppe, Anfänger sind immer willkommen!']],
      ['foto|kamera|bild|insta|natur', [
        'Ich fotografiere viel analog, gerade mit einer alten Pentax 📷',
        'Fotografierst du auch? Ich suche immer Leute für Fotowalks.']],
    ],
    question: ['Ich studiere Geografie und jobbe nebenbei in der Kletterhalle. Und du?', 'Haha, gute Frage – ich bin eher spontan 😄'],
    small: [
      'Machst du eigentlich Sport?',
      'Ich bin noch so bis {until} hier draußen – komm gern vorbei, wenn du magst!',
      'Die Sonne ist heute echt schön, oder? ☀️'],
  },
  'Alex': {
    place: 'im ruhigen Teehaus in der Altstadt, ganz hinten in der Leseecke',
    look: 'beiger Pulli, ein Buch von Marc Aurel auf dem Tisch',
    stay: 120,
    greet: ['Hallo {name} 🙏', 'Hi {name}, schön von dir zu lesen.'],
    howareyou: ['Ruhig und gut, danke. Ich sitze gerade bei einem Grüntee und lese. Und wie geht es dir?', 'Gut – ich versuche heute bewusst langsam zu machen 🙂 Und du?'],
    topics: [
      ['philosoph|stoi|marc aurel|seneca|sinn|bewusst', [
        'Gerade lese ich Marc Aurel – „Selbstbetrachtungen“ trifft mich jedes Mal wieder.',
        'Was bedeutet für dich ein gutes Leben? Ich frage mich das in letzter Zeit oft.',
        'Ich mag den Gedanken der Stoiker: nur um das kümmern, was man beeinflussen kann.']],
      ['medit|achtsam|ruhe|yoga|entschleun|stress', [
        'Ich meditiere jeden Morgen 20 Minuten – hat mein Leben ziemlich verändert.',
        'Digitale Entschleunigung ist bei mir gerade ein großes Thema. Handy abends aus 📵']],
      ['buch|bücher|lesen|lese|liest|roman|autor', [
        'Bücher sind meine Lieblingsflucht 📚 Was liest du gerade?',
        'Byung-Chul Han kann ich empfehlen, wenn du kurze, dichte Texte magst.']],
    ],
    question: ['Ich arbeite als Ergotherapeut*in, Teilzeit. Den Rest der Zeit lese ich viel 🙂 Und du?', 'Darüber würde ich gern in Ruhe sprechen – bei einem Tee vielleicht?'],
    small: [
      'Was beschäftigt dich gerade so?',
      'Ich bin noch bis {until} im Teehaus. Wenn du magst, setz dich dazu 🍵',
      'Ich finde es schön, dass man hier so offen schreiben kann.'],
  },
  'Peter': {
    place: 'im Bistro gegenüber vom Jazzclub, am Tresen',
    look: 'Schiebermütze, grauer Bart',
    stay: 90,
    greet: ['Hallo {name}! Hier duzt man sich ja – gefällt mir 😄', 'Guten Tag {name}!'],
    howareyou: ['Sehr gut, danke der Nachfrage. Ich habe heute Mittag einen herrlichen Schmorbraten gemacht. Und selbst?', 'Bestens! Rentnerleben hat seine Vorzüge 😄 Wie geht’s dir?'],
    topics: [
      ['jazz|musik|konzert|band|klavier|saxophon|swing', [
        'Am Freitag spielt ein wunderbares Trio im Jazzstudio. Magst du Jazz?',
        'Ich habe früher selbst Klavier gespielt, heute höre ich lieber zu 🎷',
        'Coltrane oder Miles Davis – das ist die Gretchenfrage 😄']],
      ['koch|essen|rezept|restaurant|wein|braten', [
        'Kochen ist meine Leidenschaft. Gerade probiere ich mich an fränkischen Klassikern neu.',
        'Hast du ein Lieblingsgericht? Ich sammle Rezepte 🙂']],
      ['philosoph|sinn|leben|alter', [
        'Mit über 60 sieht man vieles gelassener – aber die großen Fragen bleiben spannend.']],
    ],
    question: ['Ich war 35 Jahre Lehrer für Deutsch und Musik, jetzt im Ruhestand. Und du?', 'Ach, das erzähle ich gern bei einem Glas Wein 😉'],
    small: [
      'Was treibt dich so um in letzter Zeit?',
      'Ich bin noch bis {until} im Bistro. Auf einen Kaffee – oder ein Gläschen – gern!',
      'Schön, dass sich junge Leute mit alten Herren unterhalten 😄'],
  },
  'Sam': {
    place: 'in der Bäckerei mit Sitzecke an der Haltestelle',
    look: 'schwarze Cap, Rucksack',
    stay: 45,
    greet: ['hey 👋', 'hi {name}!'],
    howareyou: ['ganz gut, danke. du?', 'passt 😄 und selbst?'],
    topics: [
      ['ki|künstlich|chatgpt|claude|technolog|gaming|pc|computer', [
        'ja KI find ich mega spannend, bastel grad mit lokalen modellen rum',
        'zockst du auch? 🎮',
        'hab mir grad nen neuen pc gebaut, endlich genug grafikspeicher 😅']],
    ],
    question: ['studier info im 3. semester. du?', 'hm gute frage, keine ahnung ehrlich gesagt 😄'],
    where: ['{place} 😄 komm vorbei wenn du magst'],
    meet: ['klar, bin {place}. noch bis ca. {until} da 👍', 'gern, schaffst du das in 20 min?'],
    confirm: ['nice, bis gleich! erkennst mich an: {look}', 'top 👍 {look}, kannst mich nicht verfehlen'],
    small: [
      'bin neu hier, wie findest du die app?',
      'bin noch bis {until} hier falls du auf nen kaffee vorbeikommen willst',
      'cool 👍'],
  },
};

const GENERIC = {
  place: 'in einem Café hier in der Nähe', look: 'ich winke einfach 😄', stay: 60,
  greet: ['Hi {name}!'], howareyou: ['Gut, danke! Und dir?'], topics: [],
  question: ['Gute Frage 😄 Erzähl du mal zuerst!'],
  small: ['Was machst du so?', 'Lust auf einen Kaffee? Ich bin noch bis {until} hier.'],
};

const SHARED = {
  where: ['Ich sitze {place} 🙂 Magst du vorbeikommen?', 'Gerade {place}. Komm gern vorbei, wenn du in der Nähe bist!'],
  meet: ['Gern! Ich sitze {place}. Ich bin noch bis ca. {until} da – komm einfach vorbei 😊',
         'Klingt gut! Ich bin {place}. Schaffst du es in den nächsten 20–30 Minuten?'],
  confirm: ['Super, ich freu mich! Erkennungszeichen: {look} 👋', 'Perfekt! Du erkennst mich an: {look}. Bis gleich!'],
  when: ['Ich bin noch bis ca. {until} hier.', 'Bis {until} bin ich auf jeden Fall noch da.'],
  no: ['Kein Problem! Vielleicht ein andermal 🙂', 'Schade, aber ganz ok – wir können ja trotzdem schreiben.'],
  thanks: ['Gerne! 😊', 'Immer doch 🙂'],
  bye: ['Tschüss, war schön mit dir zu schreiben! 👋', 'Bis bald! 😊'],
  seeyou: ['Bis gleich! 👋', 'Freu mich, bis gleich 😊'],
  leave: ['Ich muss gleich leider los – war echt schön mit dir zu schreiben! Vielleicht sieht man sich 👋'],
  location: ['Danke für den Standort! Das ist ja ganz nah, ich bin {place} 😊', 'Oh, du bist ja nur ein paar Minuten weg!'],
  emoji: ['😊', '😄'],
  fallback: ['Erzähl mal mehr! 🙂', 'Spannend – wie kamst du darauf?', 'Haha, verstehe 😄', 'Und sonst so, was machst du heute noch?',
             'Ah, interessant!', 'Das kann ich gut nachvollziehen.'],
  short: ['😊', '👍', 'Haha 😄', 'Stimmt!', 'Ja, total.', '🙂'],
};

const RX = {
  location: /openstreetmap\.org|maps\.google|goo\.gl\/maps|📍/i,
  bye: /\b(tschüss|tschau|ciao|bis dann|bis später|bis bald|gute nacht|muss los|bye)\b/i,
  seeyou: /(bis gleich|bis nachher|gleich da|bin unterwegs|mach mich auf den weg|bin auf dem weg)/i,
  accept: /(komme (gleich |gern |gerne )?(vorbei|hin|rüber)|ich komm|bin dabei|ich bin gleich da|treffen wir uns)/i,
  thanks: /\b(danke|dankeschön|merci|thx)\b/i,
  meet: /(treffen|kaffee|café|cafe|vorbei ?kommen|vorbeischauen|auf einen|zusammen|sehen wir uns|kennenlernen|lust)/i,
  no: /\b(nein|leider|keine zeit|heute nicht|geht nicht|schaff.* nicht|ein andermal|nö)\b/i,
  yes: /\b(ja|jap|jo|gern|gerne|klar|super|ok|okay|passt|bin dabei|komme|machen wir|perfekt|gute idee)\b/i,
  where: /(wo (bist|sitzt|genau|denn)|welches café|welches cafe|wo seid)/i,
  when: /(wann|wie lange|bis wann|uhrzeit|noch da)/i,
  howareyou: /(wie geht|wie gehts|wie geht's|wie läuft|alles gut bei dir|was machst du gerade)/i,
  greet: /^(hallo|hi|hey|hej|servus|moin|grüß|guten (morgen|tag|abend)|na\b)/i,
};

function firstName(nick) {
  const n = String(nick || '').replace(/\s*\(.*\)\s*$/, '').replace(/[\d_]+$/, '').trim();
  return n || 'du';
}

function fmtTime(d) {
  return d.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Berlin' });
}

function fill(text, p, humanName, now) {
  const until = new Date(Math.ceil((now.getTime() + p.stay * 60000) / 900000) * 900000);
  return text.replace(/\{name\}/g, firstName(humanName))
    .replace(/\{place\}/g, p.place).replace(/\{look\}/g, p.look).replace(/\{until\}/g, fmtTime(until));
}

// history: [{ fromBot: boolean, text: string }] in chronological order
export function pickReply({ bot, humanName, history, now = new Date() }) {
  // Personas are keyed by first name, so the suffix ("(KI)", formerly "(Test)") does not matter
  const p = PERSONAS[String(bot || '').replace(/\s*\(.*\)\s*$/, '').trim()] || GENERIC;
  const botTexts = history.filter(m => m.fromBot).map(m => m.text);
  let lastBotIdx = -1;
  history.forEach((m, i) => { if (m.fromBot) lastBotIdx = i; });
  const pending = history.slice(lastBotIdx + 1).filter(m => !m.fromBot).map(m => m.text).join('\n');
  const lastBot = lastBotIdx >= 0 ? history[lastBotIdx].text : '';
  const humanCount = history.filter(m => !m.fromBot).length;
  const t = pending.trim();

  // A template counts as used if its filled-in text (without time) already appeared
  const isUsed = (tpl) => {
    const probe = fill(tpl, p, humanName, now).replace(/\d\d:\d\d/g, '');
    return botTexts.some(b => b.replace(/\d\d:\d\d/g, '').includes(probe));
  };
  const take = (arr) => {
    const tpl = (arr || []).find(x => !isUsed(x));
    return tpl ? fill(tpl, p, humanName, now) : null;
  };

  const pick = (key) => p[key] || SHARED[key];
  const confirmed = botTexts.some(b => /(erkennungszeichen|erkennst mich|bis gleich)/i.test(b));
  const norm = (x) => x.replace(/\d\d:\d\d/g, '');
  const sentFrom = (arr) => arr.some(tpl => botTexts.some(b => norm(b).includes(norm(fill(tpl, p, humanName, now)))));
  const offeredMeet = !confirmed && (sentFrom(pick('meet')) || sentFrom(pick('where')) ||
    botTexts.some(b => /(vorbei|treffen|kaffee|tee\b|gläschen|schaffst du|setz dich dazu)/i.test(b) && /\?|!|😊|👍/.test(b)));
  const greeted = RX.greet.test(t) && humanCount <= 1;

  const steps = [];
  if (RX.location.test(t)) steps.push(SHARED.location);
  if (RX.seeyou.test(t) && confirmed) steps.push(SHARED.seeyou);
  if (RX.bye.test(t)) steps.push(SHARED.bye);
  if (offeredMeet && RX.no.test(t)) steps.push(SHARED.no);
  if ((offeredMeet && RX.yes.test(t)) || RX.accept.test(t)) steps.push(pick('confirm'));
  if (RX.meet.test(t) && !RX.no.test(t) && !confirmed) steps.push(pick('meet'));
  if (RX.where.test(t)) steps.push(pick('where'));
  if (RX.when.test(t)) steps.push(SHARED.when);
  for (const [rx, lines] of p.topics) if (new RegExp(rx, 'i').test(t)) steps.push(lines);
  if (RX.howareyou.test(t)) steps.push(p.howareyou);
  if (RX.seeyou.test(t)) steps.push(SHARED.seeyou);
  if (RX.thanks.test(t)) steps.push(SHARED.thanks);
  if (t.includes('?')) steps.push(p.question);
  if (/^[\p{Extended_Pictographic}\s]+$/u.test(t)) steps.push(SHARED.emoji);

  for (const s of steps) {
    const r = take(s);
    if (!r) continue;
    const g = greeted ? take(p.greet) : null;
    return g ? g + ' ' + r : r;
  }
  if (greeted || (humanCount <= 1 && !botTexts.length)) {
    const g = take(p.greet);
    if (g) return g;
  }
  const generic = take(p.small) || (botTexts.length >= 10 ? take(SHARED.leave) : null) || take(SHARED.fallback);
  if (generic) return generic;
  const shorts = SHARED.short.filter(x => x !== lastBot);
  return shorts[botTexts.length % shorts.length];
}

export const PERSONA_NAMES = Object.keys(PERSONAS);
