## Design proposal

**Give each box a reading page, and give the index a way to unfold it.** Someone arriving at *The Cable Man* should first encounter the box and the writing that gives it a character. Someone looking for a particular station break should be able to find the reel in the index and go straight to it.

- **Collection page.** Use the reel page’s two-column opening. On the left, show the box as it arrived, with a small caption. On the right, set “Collection” in the size currently used for a catalog number, followed by the owner’s title, the place and date found, and the essay. Put a link such as “6 reels” beside the finding details. It jumps past the essay to the inventory. Additional photographs use the reel page’s existing photo stepper and original-image viewer.
- **Reel inventory.** Below the opening, return to the width and rhythm of the existing index. Each row is one link with the displayed catalog number, title, estimated recording date, and total running time. Sort by RA number, even when the numbers have gaps. The site already displays `014` and links to `/archive/RA-014`. Keeping that convention lets readers recognize a reel across both views. The finding date belongs to the box. The dates in the inventory belong to the recordings.
- **Audio.** I’d launch with playback on the reel page. A title like *Station break, three endings* is an invitation to listen, and opening it gives the listener the track names, notes, and seek control together. If listening across a box becomes important, add a separate “Preview” button beside each playable row. It would play up to 30 seconds of the first playable track, change to “Pause,” and stop when another preview starts. The title would still open the reel. The mockup shows the launch version.
- **Index.** Put two text links below “Index,” labeled **By RA number** and **By collection**, with an underline on the current view. Keep `/recordings` as the default and give the grouped view `/recordings?view=collections`. Each collection gets a disclosure showing its name, where and when it was found, and its public reel count. Unfolding it reveals “Read collection” and the individual reel links. Alphabetize boxes by name, ignoring a leading “The,” and put **Reels outside collections** last. That last group matters because many reels may be the only object from a find.
- **Search.** Keep the existing search field and `q` in the address when switching views. A collection-name or finding-place match opens the whole group. A reel-title or RA-number match opens the group with just the matching rows and a count such as “1 of 6 reels.” Searching `RA-014` or `014` should reach the same item. The grouped view searches public material only.
- **On a reel page.** Add a linked line beneath the object facts, for example “From the collection *The Cable Man*.” At the end of the essay, repeat the collection name above two links such as “Previous · 019 Station break, three endings” and “Next · 028 Calls after the game.” These follow the collection’s public RA order, independent of a search. At either end, show only the available direction. Keep the existing return link sensitive to arrival context. Coming from a box gives “Back to The Cable Man,” landing at the reel’s row. Coming from the grouped index restores the search and open group. Coming from the objects page preserves its page number.
- **Sparse and growing collections.** One public reel gets a singular count, a normal inventory row, and no sibling navigation. A public reel with no public collection appears under “Reels outside collections” and has no collection line. This also keeps a draft box’s name private. A published box with zero public reels can still carry the essay and photos, followed by “No reels published yet.” Counts describe what can be opened today. A missing essay closes the space before the inventory. A long essay runs in full at the reel page’s reading width, with the early reel-count link providing a shortcut. With no photos, use a single reading column and move the inventory up.
- **Phone.** Follow the existing 900px reading-page breakpoint and 720px index breakpoint. Stack the return link, title, finding details and reel jump, photograph, essay, and inventory in that order. In each row, keep the number beside the title, then place the date and duration on a second line. Make the disclosure and reel rows full-width tap targets. Long titles can wrap.

**What’s observed and what’s proposed.** The working tree uses EB Garamond, `#faf5ee` paper with faint grain, `#211d19` ink, 24–66px gutters, and an unframed finding list. The home page is an arrangement of objects, while `/recordings` is the index. I’d confine the switch to the index so those two entrances keep their distinct purposes. The collection layouts, sample holdings, dates, inscriptions, and prose below are invented. The first mockup uses a self-contained illustration of a lid to show the photograph’s scale and placement. Both mockups use the site’s serif fallbacks if EB Garamond is unavailable locally. [Current styles](/Users/colton/code/me/web/remanence-archive/src/app/globals.css) · [Index component](/Users/colton/code/me/web/remanence-archive/src/components/index-list.tsx) · [Reel page](</Users/colton/code/me/web/remanence-archive/src/app/archive/[slug]/page.tsx>)

## 1. Collection page

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>The Cable Man — Remanence Archive</title>
  <style>
    :root {
      --paper: #faf5ee;
      --ink: #211d19;
      --muted: #625a51;
      --rule: rgb(33 29 25 / 19%);
      --gutter: clamp(24px, 4.3vw, 66px);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font: 18px/1.5 "EB Garamond", "Iowan Old Style", "Palatino Linotype", Georgia, serif;
      font-variant-numeric: oldstyle-nums;
      -webkit-font-smoothing: antialiased;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: 5;
      pointer-events: none;
      opacity: .032;
      mix-blend-mode: multiply;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='220' height='220'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Cpath fill='%23877' filter='url(%23n)' d='M0 0h220v220H0z'/%3E%3C/svg%3E");
    }
    a { color: inherit; text-decoration: none; }
    a:focus-visible { outline: 1px solid var(--ink); outline-offset: 3px; }
    a:hover, .jump { text-decoration: underline; text-underline-offset: 4px; }
    ::selection { color: var(--paper); background: var(--ink); }
    header {
      height: 76px;
      padding: 0 var(--gutter);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .name { font-size: 21px; letter-spacing: .005em; padding: 12px 0; }
    header nav { display: flex; gap: 8px; margin-right: -12px; }
    header nav a { padding: 12px; font-size: 16.5px; }
    main { padding: 30px calc(var(--gutter) + 30px) 110px; }
    .back { display: inline-block; padding: 8px 0; }
    .opening {
      display: grid;
      grid-template-columns: minmax(0,594fr) minmax(0,630fr);
      grid-template-areas: "object title" "object essay";
      gap: 0 clamp(40px,7.8vw,120px);
      align-items: start;
      margin-top: 20px;
    }
    .heading { grid-area: title; }
    .kind, .facts, .inventory { font-variant-numeric: lining-nums; }
    .kind { margin: 0; font-size: 15px; letter-spacing: .02em; }
    h1 { margin: 12px 0 18px; font-size: 32px; line-height: 1.22; font-weight: 400; }
    .facts { margin: 0; font-size: 17px; line-height: 1.45; }
    .jump { display: inline-block; padding: 4px 0; }
    .essay {
      grid-area: essay;
      max-width: 630px;
      margin-top: 24px;
      font-size: 21.5px;
      line-height: 30px;
    }
    .essay p { margin: 0 0 18px; text-wrap: pretty; }
    figure { grid-area: object; margin: 0; align-self: center; }
    /* A study of the lid occupies the place of the original box photograph. */
    .lid {
      position: relative;
      isolation: isolate;
      width: 89%;
      aspect-ratio: 1.48;
      margin: 24px auto 26px;
      transform: rotate(-3deg);
      border: 1px solid #968365;
      border-radius: 4px 2px 7px 2px;
      color: #40382d;
      background:
        linear-gradient(92deg, transparent 47%, #98836140 48%, transparent 49%),
        repeating-linear-gradient(3deg, #8a755514 0 1px, transparent 1px 4px),
        linear-gradient(117deg, #c6b28d, #d8c6a4 39%, #bdab89 92%);
      box-shadow: inset 3px 4px 0 #e1cfac, inset -4px -7px 0 #a49374;
    }
    .lid::before {
      content: "";
      position: absolute;
      inset: 0 auto 0 10%;
      width: 7%;
      background: linear-gradient(90deg, #ae935f55, #d6bd8255 74%, #a0855740);
      border-inline: 1px solid #997e5370;
      z-index: -1;
    }
    .tag {
      position: absolute;
      left: 24%;
      top: 25%;
      width: 58%;
      padding: 5% 5% 4%;
      transform: rotate(1.8deg);
      background: #eae2cd;
      border: 1px solid #b3a48a;
      font: italic clamp(17px,2.05vw,31px)/1.13 "Iowan Old Style", Georgia, serif;
    }
    .tag small {
      display: block;
      margin-top: 10px;
      padding-top: 5px;
      border-top: 1px solid #a79c85;
      font-size: .65em;
    }
    .pencil {
      position: absolute;
      right: 10%;
      bottom: 13%;
      transform: rotate(-5deg);
      font-style: italic;
      color: #615443;
      font-size: clamp(13px,1.25vw,19px);
    }
    figcaption { margin-left: 5%; font-size: 14px; color: var(--muted); }
    .inventory { max-width: 845px; margin: 66px auto 0; scroll-margin-top: 24px; }
    h2 {
      margin: 0 0 10px;
      padding-bottom: 12px;
      border-bottom: 1px solid var(--rule);
      font-weight: 400;
      font-size: 23px;
    }
    ul { margin: 0; padding: 0; list-style: none; }
    .row {
      display: grid;
      grid-template-columns: 78px minmax(0,1fr) minmax(115px,.38fr) auto;
      gap: 12px;
      align-items: baseline;
      padding: 15px 0;
      font-size: 21px;
      line-height: 31px;
    }
    .row:hover { text-decoration: none; }
    .row:hover .title { text-decoration: underline; text-underline-offset: 4px; }
    .no { font-size: 16px; }
    .length { text-align: right; font-variant-numeric: lining-nums tabular-nums; }
    @media (max-width: 900px) {
      main { padding: 12px var(--gutter) 80px; }
      .opening {
        max-width: 630px;
        margin: 16px auto 0;
        grid-template-columns: minmax(0,1fr);
        grid-template-areas: "title" "object" "essay";
      }
      h1 { font-size: 28px; }
      figure { width: min(100%,440px); margin: 16px 0 0; }
      .lid { width: 85%; }
      .essay { font-size: 20px; line-height: 29px; }
      .inventory { margin-top: 40px; }
    }
    @media (max-width: 720px) {
      header { height: 68px; }
      .row {
        grid-template-columns: 46px minmax(0,1fr) auto;
        grid-template-areas: "no title title" ". date length";
        gap: 0 8px;
        padding: 13px 0;
        font-size: 19px;
        line-height: 26px;
        border-bottom: 1px solid var(--rule);
      }
      .no { grid-area: no; }
      .title { grid-area: title; }
      .date { grid-area: date; }
      .length { grid-area: length; }
      .date, .length { font-size: 16px; }
    }
  </style>
</head>
<body>
  <header>
    <a class="name" href="/">Remanence Archive</a>
    <nav aria-label="Site"><a href="/recordings">Index</a><a href="/about">About</a></nav>
  </header>

  <main>
    <a class="back" href="/recordings?view=collections#the-cable-man">Back to collections</a>

    <div class="opening">
      <div class="heading">
        <p class="kind">Collection</p>
        <h1>The Cable Man</h1>
        <p class="facts">
          Found at a garage sale in Joliet, Illinois, October 2023<br>
          <a class="jump" href="#reels">6 reels</a>
        </p>
      </div>

      <figure>
        <div class="lid" role="img"
             aria-label="Study of a cardboard lid. A paper label reads “Cable — local. Breaks &amp; effects.” In pencil below it, “keep the short ones.”">
          <span class="tag" aria-hidden="true">Cable — local<small>Breaks &amp; effects</small></span>
          <span class="pencil" aria-hidden="true">keep the short ones</span>
        </div>
        <figcaption>The box lid, with a second instruction in pencil. Illustration.</figcaption>
      </figure>

      <div class="essay">
        <p>The box was under a card table with a crimping tool and a coffee tin
          full of cable ends. On the lid someone had written “keep the short
          ones.” The shortest thing in the box is a station break that lasts
          just long enough for three voices to sing the name of a town.</p>
        <p>There are three endings to that tune. On the first, a bass player
          lets the last note ring. On the second, somebody puts a hand on the
          strings. The third ends in the middle of the word “Joliet.” All
          three were wound onto one reel, with a little white leader between
          them.</p>
        <p>I think these belonged to someone who worked on the local cable
          system. The line checks give me that impression. What I keep coming
          back to is the rain reel. After the gutter stops rattling, whoever
          held the microphone stayed out there for another minute.</p>
      </div>
    </div>

    <section class="inventory" id="reels" aria-labelledby="inventory-title">
      <h2 id="inventory-title">Reels in this collection</h2>
      <ul>
        <li id="RA-014"><a class="row" href="/archive/RA-014?from=the-cable-man">
          <span class="no">014</span><span class="title">Line check from the headend</span>
          <span class="date"><i>c.</i> 1978</span><span class="length">4:16</span>
        </a></li>
        <li id="RA-019"><a class="row" href="/archive/RA-019?from=the-cable-man">
          <span class="no">019</span><span class="title">Station break, three endings</span>
          <span class="date"><i>c.</i> 1978–80</span><span class="length">1:42</span>
        </a></li>
        <li id="RA-023"><a class="row" href="/archive/RA-023?from=the-cable-man">
          <span class="no">023</span><span class="title">Rain in the downspout</span>
          <span class="date">Undated</span><span class="length">6:08</span>
        </a></li>
        <li id="RA-028"><a class="row" href="/archive/RA-028?from=the-cable-man">
          <span class="no">028</span><span class="title">Calls after the game</span>
          <span class="date">1981</span><span class="length">18:37</span>
        </a></li>
        <li id="RA-031"><a class="row" href="/archive/RA-031?from=the-cable-man">
          <span class="no">031</span><span class="title">Doors, latches, one deadbolt</span>
          <span class="date">Undated</span><span class="length">3:54</span>
        </a></li>
        <li id="RA-037"><a class="row" href="/archive/RA-037?from=the-cable-man">
          <span class="no">037</span><span class="title">Music to run under the weather</span>
          <span class="date"><i>c.</i> 1982</span><span class="length">9:21</span>
        </a></li>
      </ul>
    </section>
  </main>
</body>
</html>
```

## 2. Index by collection

This sample opens *The Cable Man* so the relationship between the essay and the six reel links is visible on first look. The disclosures, search, and view switch work within the mockup. Links to archive pages show their intended site addresses.

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Index — Remanence Archive</title>
  <style>
    :root {
      --paper: #faf5ee;
      --ink: #211d19;
      --muted: #625a51;
      --rule: rgb(33 29 25 / 19%);
      --gutter: clamp(24px, 4.3vw, 66px);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--paper);
      color: var(--ink);
      font: 18px/1.5 "EB Garamond", "Iowan Old Style", "Palatino Linotype", Georgia, serif;
      font-variant-numeric: oldstyle-nums;
      -webkit-font-smoothing: antialiased;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: 5;
      pointer-events: none;
      opacity: .032;
      mix-blend-mode: multiply;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='220' height='220'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Cpath fill='%23877' filter='url(%23n)' d='M0 0h220v220H0z'/%3E%3C/svg%3E");
    }
    a { color: inherit; text-decoration: none; }
    a:hover, .views [aria-current], .read, footer a {
      text-decoration: underline;
      text-decoration-thickness: 1px;
      text-underline-offset: 4px;
    }
    :is(a,summary,input):focus-visible { outline: 1px solid var(--ink); outline-offset: 3px; }
    ::selection { color: var(--paper); background: var(--ink); }
    header {
      height: 76px;
      padding: 0 var(--gutter);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .name { font-size: 21px; letter-spacing: .005em; padding: 12px 0; }
    header nav { display: flex; gap: 8px; margin-right: -12px; }
    header nav a { font-size: 16.5px; padding: 12px; }
    main {
      padding: 56px var(--gutter) 100px
        calc(var(--gutter) + clamp(0px,11.5vw,176px));
    }
    .head {
      display: flex;
      max-width: 886px;
      align-items: baseline;
      justify-content: space-between;
      gap: 24px;
    }
    h1 { margin: 0; font-size: 23px; font-weight: 400; }
    input {
      width: 140px;
      min-width: 0;
      max-width: 57%;
      padding: 6px 0 3px;
      color: inherit;
      background: transparent;
      border: 0;
      border-radius: 0;
      border-bottom: 1px solid;
      font: inherit;
      appearance: none;
    }
    input:focus { width: 220px; }
    input::placeholder { color: var(--ink); opacity: 1; }
    .views { display: flex; gap: 24px; margin: 10px 0 28px; }
    .views a { padding: 9px 0; }
    #results { max-width: 845px; }
    details { border-top: 1px solid var(--rule); }
    details:last-child { border-bottom: 1px solid var(--rule); }
    summary {
      display: grid;
      grid-template-columns: 20px minmax(0,1fr) auto;
      gap: 0 10px;
      align-items: baseline;
      padding: 16px 0;
      list-style: none;
      cursor: pointer;
    }
    summary::-webkit-details-marker { display: none; }
    .marker { font-size: 16px; text-align: center; }
    .marker::before { content: "+"; }
    details[open] > summary .marker::before { content: "−"; }
    .group-name { font-size: 23px; line-height: 1.3; }
    .count, .place { color: var(--muted); font-size: 16px; }
    .count { white-space: nowrap; font-variant-numeric: lining-nums; }
    .place { grid-column: 2 / -1; margin-top: 2px; }
    .inside { padding: 0 0 20px 30px; }
    .read { font-size: 17px; display: inline-block; padding: 5px 0 10px; }
    ul { list-style: none; margin: 0; padding: 0; }
    .row {
      display: grid;
      grid-template-columns: 68px minmax(0,1fr) minmax(115px,.38fr) auto;
      gap: 12px;
      align-items: baseline;
      padding: 10px 0;
      font-size: 21px;
      line-height: 31px;
      font-variant-numeric: lining-nums;
    }
    .flat .row { padding: 15px 0; }
    .row:hover { text-decoration: none; }
    .row:hover .title { text-decoration: underline; text-underline-offset: 4px; }
    .no { font-size: 16px; }
    .length { text-align: right; font-variant-numeric: lining-nums tabular-nums; }
    footer { margin-top: 58px; }
    @media (max-width: 720px) {
      header { height: 68px; }
      main { padding: 28px var(--gutter) 80px; }
      .views { gap: 18px; margin-bottom: 20px; }
      .group-name { font-size: 21px; }
      summary { grid-template-columns: 14px minmax(0,1fr) auto; gap: 0 7px; }
      .inside { padding-left: 0; }
      .read { margin-left: 21px; }
      .row, .flat .row {
        grid-template-columns: 46px minmax(0,1fr) auto;
        grid-template-areas: "no title title" ". date length";
        gap: 0 8px;
        font-size: 19px;
        line-height: 26px;
        padding: 13px 0;
        border-bottom: 1px solid var(--rule);
      }
      .inside li:last-child .row { border: 0; }
      .no { grid-area: no; }
      .title { grid-area: title; }
      .date { grid-area: date; }
      .length { grid-area: length; }
      .date, .length { font-size: 16px; }
    }
  </style>
</head>
<body>
  <header>
    <a class="name" href="/">Remanence Archive</a>
    <nav aria-label="Site"><a href="/recordings">Index</a><a href="/about">About</a></nav>
  </header>

  <main>
    <div class="head">
      <h1>Index</h1>
      <input id="find" type="search" placeholder="Find a recording"
             aria-label="Find a recording or collection" aria-controls="results">
    </div>
    <nav class="views" aria-label="Index view">
      <a id="numbers" href="?view=number">By RA number</a>
      <a id="collections" href="?view=collections" aria-current="page">By collection</a>
    </nav>
    <div id="results"></div>
    <p id="empty" role="status" hidden>Nothing matches.</p>
    <footer><a href="/">View objects</a></footer>
  </main>

  <script>
    const groups = [
      {
        name: "The Cable Man", slug: "the-cable-man",
        found: "Joliet, Illinois · October 2023",
        reels: [
          ["014", "Line check from the headend", "c. 1978", "4:16"],
          ["019", "Station break, three endings", "c. 1978–80", "1:42"],
          ["023", "Rain in the downspout", "Undated", "6:08"],
          ["028", "Calls after the game", "1981", "18:37"],
          ["031", "Doors, latches, one deadbolt", "Undated", "3:54"],
          ["037", "Music to run under the weather", "c. 1982", "9:21"]
        ]
      },
      {
        name: "The Kitchen Window", slug: "the-kitchen-window",
        found: "Dubuque, Iowa · April 2022",
        reels: [
          ["011", "The freight crossing, from upstairs", "1972", "7:11"],
          ["025", "Supper with the window open", "c. 1973", "12:08"]
        ]
      },
      {
        name: "Reels outside collections", slug: "", found: "",
        reels: [
          ["008", "Piano lesson, left hand alone", "Undated", "11:05"],
          ["022", "Last waltz at the parish hall", "1967", "8:49"]
        ]
      }
    ];

    const find = document.querySelector("#find");
    const results = document.querySelector("#results");
    const empty = document.querySelector("#empty");
    const numbers = document.querySelector("#numbers");
    const collections = document.querySelector("#collections");
    const params = new URLSearchParams(location.search);
    const byCollection = params.get("view") !== "number";
    const initiallyOpen = groups.find(group => "#" + group.slug === location.hash);
    const openGroups = new Set([initiallyOpen?.name || groups[0].name]);
    find.value = params.get("q") || "";

    function element(tag, className, label) {
      const item = document.createElement(tag);
      if (className) item.className = className;
      if (label !== undefined) item.textContent = label;
      return item;
    }

    function indexQuery(view) {
      const query = new URLSearchParams({ view });
      if (find.value) query.set("q", find.value);
      return "?" + query;
    }

    function reelList(reels) {
      const list = element("ul", byCollection ? "" : "flat");
      for (const [number, title, date, length] of reels) {
        const entry = element("li");
        const link = element("a", "row");
        const context = new URLSearchParams();
        if (byCollection) context.set("view", "collections");
        if (find.value) context.set("q", find.value);
        link.href = "/archive/RA-" + number + (context.size ? "?" + context : "");

        const recorded = element("span", "date");
        if (date.startsWith("c. ")) {
          recorded.append(element("i", "", "c."), " " + date.slice(3));
        } else {
          recorded.textContent = date;
        }
        link.append(element("span", "no", number), element("span", "title", title),
          recorded, element("span", "length", length));
        entry.append(link);
        list.append(entry);
      }
      return list;
    }

    function collectionGroup(group, reels, searching) {
      const details = element("details");
      if (group.slug) details.id = group.slug;
      details.open = searching || openGroups.has(group.name);

      const summary = element("summary");
      const marker = element("span", "marker");
      marker.setAttribute("aria-hidden", "true");
      const total = group.reels.length;
      const count = (reels.length === total ? total : reels.length + " of " + total)
        + (total === 1 ? " reel" : " reels");
      summary.append(marker, element("span", "group-name", group.name),
        element("span", "count", count));
      if (group.found) summary.append(element("span", "place", "Found in " + group.found));

      const inside = element("div", "inside");
      if (group.slug) {
        const read = element("a", "read", "Read collection");
        read.href = "/collections/" + group.slug;
        if (find.value) read.search = new URLSearchParams({ q: find.value }).toString();
        read.setAttribute("aria-label", "Read collection, " + group.name);
        inside.append(read);
      }
      inside.append(reelList(reels));
      details.append(summary, inside);
      details.addEventListener("toggle", () => {
        if (searching || !details.isConnected) return;
        if (details.open) openGroups.add(group.name);
        else openGroups.delete(group.name);
      });
      return details;
    }

    function render() {
      const words = find.value.toLowerCase().trim().split(/\s+/).filter(Boolean);
      const flat = [];
      results.replaceChildren();
      numbers.href = indexQuery("number");
      collections.href = indexQuery("collections");
      numbers.removeAttribute("aria-current");
      collections.removeAttribute("aria-current");
      (byCollection ? collections : numbers).setAttribute("aria-current", "page");

      for (const group of groups) {
        const shared = (group.name + " " + group.found).toLowerCase();
        const matches = group.reels.filter(([number, title, date]) => {
          const text = `${shared} ra-${number} ${title} ${date}`.toLowerCase();
          return words.every(word => text.includes(word));
        });
        const groupMatches = words.every(word => shared.includes(word));
        if (byCollection && (matches.length || groupMatches)) {
          results.append(collectionGroup(group, matches, words.length > 0));
        }
        flat.push(...matches);
      }
      if (!byCollection && flat.length) {
        flat.sort((a, b) => Number(a[0]) - Number(b[0]));
        results.append(reelList(flat));
      }
      empty.hidden = results.childElementCount > 0;
    }

    find.addEventListener("input", () => {
      render();
      // Keep a hosted mock shareable. Local-file previews also work offline.
      if (location.protocol === "http:" || location.protocol === "https:") {
        history.replaceState(null, "", indexQuery(byCollection ? "collections" : "number"));
      }
    });
    render();
  </script>
</body>
</html>
```