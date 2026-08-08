# MVP2: natural-language schedule input

Natural-language schedule entry is intentionally deferred from the current MVP.

A future administrator experience may accept text such as:

> Thursday class is 6:30 PM to 7:00 PM and Friday is 5:00 PM to 6:00 PM. Kiran handles both days this week, Mohan handles both days next week, and the pattern repeats.

KCP should never publish directly from that text. The safe workflow is:

1. Parse the explanation into the existing generic schedule-plan model.
2. Show the interpreted weekdays, outbound/return times, recurrence, rotation unit, driver order and first rotation date.
3. Highlight anything ambiguous or missing.
4. Require explicit administrator confirmation.
5. Populate the same weekly matrix and driver step used for manual setup.
6. Preview through the existing PostgreSQL occurrence resolver.
7. Publish only after the normal preview confirmation.

MVP2 acceptance must also include regression fixtures for ambiguous day names, missing AM/PM, conflicting times, skipped weeks, one-way rides, overnight returns and unknown parent names. The parser must ask for clarification rather than silently filling any of those gaps.

This remains an MVP2 item because accurate parsing requires ambiguity handling, locale/time interpretation, safe confirmation, and additional regression fixtures. The current MVP keeps all schedule creation deterministic through structured controls.
