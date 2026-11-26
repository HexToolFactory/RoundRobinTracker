# Changelog

## 0.9.0
- Scourgestones (Minion's, Invader's, Corruptor's): group members without the Argent Dawn Commission buff are left out
  of the round. They show "-" in the window and the table, are not in the turn line, and the round message names them:
  "round 1 complete (left out: Bob Stone - no Argent Dawn Commission)".
- The buff is read out of combat only; the last state read is kept. Looting a Scourgestone counts as having it.
- `/rrt commission` lists who has it.

## 0.8.1
First release.
- Pick one or more items; every group member's loot of them is counted until you reset.
- Small window: players as rows (alphabetical), items as columns, highest count green, lowest red.
- Fix any number: click a cell to type it, right-click -1, Shift-click +1.
- Add box with suggestions for every item: bags, recent loot, items tracked before, the full item list.
- Group chat:
  - when a tracked item is up for roll: whose turn it is, then the table,
  - "round N complete" once everyone has N,
  - "X broke the round" when someone loots while ahead of the lowest member.
- Report button posts the table like Details does. During combat chat is locked; messages post when it opens.
- Roll wins count even when no "receives loot" line follows.
