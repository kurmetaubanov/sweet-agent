---
name: frontend-check
description: Frontend and UI changes — how to make sure live that it works before reporting: start the app, walk the main path, check the neighbouring screens. Frontend or UI change, verify in a browser, playwright.
---

# Checking a frontend change

Type checking and a green test suite prove the code is well-formed. They do
not prove the feature works. For a UI change the only evidence is the feature
used in a browser.

## The order

1. Start the app the way the project starts it (`npm run dev`, `mix phx.server`,
   the documented command). Use a background job for the server — it keeps
   running, and the turn does not wait for it.
2. Open the page and do the thing the human asked for, with real input.
3. Walk the edge cases that belong to this change: empty state, long text, a
   value that fails validation, a slow or failing request.
4. Look at the screens next to it. A shared component, a changed route, a new
   global style — these break neighbours, and the neighbour is where the human
   notices it first.
5. Read the browser console and the server log. A feature that works while
   printing an error is not finished.

## Driving the browser

Playwright is available in the hand. Two habits save most of the time:

* wait for an event, not for a clock — `wait_for_selector`,
  `expect_response`, `wait_for_load_state`. A fixed sleep is both slower and
  less reliable than the thing it replaces;
* one script per task, edited as you go, not a new file per step. Shared
  pieces (login, opening a section) belong in a module you import.

Take a screenshot when you need to see what is on the screen, not to locate
elements: read the DOM for that.

## When you cannot check it

Say so, plainly, in the report: "the change compiles and the tests pass; I
could not open the UI because X". That is a complete, honest result. Claiming
success from a green build is not — and it is found out immediately, by the
person who opens the page.
