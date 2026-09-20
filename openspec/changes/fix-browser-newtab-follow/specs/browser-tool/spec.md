## ADDED Requirements

### Requirement: Following a new tab does not depend on a fixed short wait

The worker SHALL decide whether a click opens a new page by looking at the clicked element BEFORE the click (`target="_blank"` and equivalent named/new-window targets), and SHALL use a longer bounded wait for such clicks than for ordinary ones. Both waits SHALL be upper bounds only: the worker SHALL proceed as soon as a new page appears. An ordinary click (one that does not open a new page) SHALL NOT wait longer than it does today. Independently of what that pre-check concluded, after the wait expires the worker SHALL compare the browser's page set against the set recorded before the click and adopt a page that appeared meanwhile. When the pre-check said the click opens a new page but no new page is found within the bound, the worker SHALL record that fact on its observability channel (never in the model-visible response, and never as a failure). A failure to perform the pre-check SHALL be treated as "does not open a new page", and SHALL NOT fail the click.

#### Scenario: A new tab that appears later than the ordinary wait window is still followed

- **WHEN** the agent clicks a `target="_blank"` link whose new page registers after the ordinary wait window has already expired (measured case: the page opens about 1.5s after the click, while the ordinary window is 1s)
- **THEN** the worker SHALL follow that page (make it active, wait for it to load, snapshot it), so the response carries the landing page rather than the page that was clicked

#### Scenario: An ordinary in-place click pays no extra wait

- **WHEN** the agent clicks an element that does not open a new page
- **THEN** the worker SHALL keep today's wait window (no additional delay), and the click's response SHALL be produced as it is today

#### Scenario: A judged new-tab click that opens nothing is recorded, not failed

- **WHEN** the pre-check concluded the click opens a new page, but no new page is found within the bounded wait nor in the page-set comparison
- **THEN** the worker SHALL still return a successful response for the click (the in-place outcome), and SHALL record on its observability channel that a new tab was expected but not observed

#### Scenario: The pre-check itself failing never fails the click

- **WHEN** the pre-check (reading the clicked element's target) cannot be performed, e.g. the selector no longer matches or the element is removed
- **THEN** the worker SHALL proceed with the ordinary wait window as if the element does not open a new page, and SHALL NOT report the click as failed because of the pre-check
