# Changelog

## 0.9.0
- Left out of the round: group members while offline (any item), and for Minion's, Invader's and Corruptor's
  Scourgestone those without the Argent Dawn Commission buff (after 60 s, so a trinket swap or reconnect does nothing).
- Left out = "-" in the window and the table, not in the turn line, and a round can finish without them. The round
  message names them with the reason: "round 2 complete (left out: Bob Stone - no Argent Dawn Commission)".
- Once back their count is the lowest: the next drops are theirs until they caught up.
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
