# Round Robin Tracker

A World of Warcraft: Forever addon for round robin loot. Pick the items your group shares in turn (Righteous Orbs,
Scourgestones, ...). It counts how many each group member loots until you reset, and tells the group whose turn it is.

## Window
`/rrt` opens a small window: one row per player (alphabetical), one column per item.
Highest count green, lowest red.

- **+** adds an item: type a name (suggestions for every item), an item ID, Shift-click a link or drop an item.
- Right-click an item icon to stop tracking it.
- Click a cell to type a number, right-click -1, Shift-click +1.
- **Report** posts the table to group chat. **Reset** (click twice) sets all counts to 0.
- Esc does not close the window.

## Group chat
```
Round Robin: [Righteous Orb] up for roll, turn: Anna Berg, Bob Stone (0)
Round Robin: [Righteous Orb] (since 20:15)
1. Abe Odus ..... 1
2. Anna Berg .... 0
3. Bob Stone .... 0
Round Robin: Abe Odus broke the round on [Righteous Orb] (had 1, Anna Berg, Bob Stone have 0)
Round Robin: [Righteous Orb] round 1 complete
```

- When a tracked item is up for roll: whose turn it is (lowest count), then the table.
- When everyone has N of an item: "round N complete".
- When someone loots an item while having more than the lowest member: "broke the round".

WoW: Forever locks addon chat during combat. Messages wait and post as soon as it opens.

## Left out: offline, or no Argent Dawn Commission
A group member is left out of the round while offline (any item), or for Minion's, Invader's and Corruptor's
Scourgestone while not wearing the Argent Dawn Commission (Scourgestones drop only for players wearing it).
They show "-" in the window and the table, a round can finish without them, and the round message says why:
```
Round Robin: [Corruptor's Scourgestone] round 2 complete (left out: Bob Stone - no Argent Dawn Commission)
```
Once back (online, or wearing it), their count is the lowest again: the next drops are theirs until they caught up,
and anyone else taking one "broke the round".

- A missing buff counts only after 60 s, so a trinket swap or a reconnect changes nothing.
- Buffs can only be read out of combat; the last state read is kept. Looting a Scourgestone proves the commission.
- `/rrt commission` shows who has it.

## Commands
```
/rrt                     window
/rrt add <item>          track (link, ID or name)
/rrt remove <item|nr>    stop tracking
/rrt list                table in your chat only
/rrt report              table to group chat
/rrt reset               all counts to 0
/rrt announce on|off     round complete / broke the round messages
/rrt autoreport on|off   table when a tracked item is up for roll
/rrt commission          who has the Argent Dawn Commission
```

## How it counts
From the loot lines in chat ("receives loot", "You receive loot", "won"), read in your client's language.
A roll win counts even when no loot line follows; the loot line right after a win is not counted twice.

## License
GPLv3. The item name list (`Items.lua`) is built from [QuestieDB](https://github.com/Questie/QuestieDB) data (GPLv3)
and the game's item table by `tools/gen_items.py`.
