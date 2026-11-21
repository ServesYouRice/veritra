# C8: raising the member limit in steps

Status: step 1 built (2026-11-01). Step 2 is ready to measure: the tool and
the command are in the evidence file (2026-11-21); the run itself waits for the
owner's host. Later steps wait for the checks below.

The member limit is `PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS` (D38,
`docs/operations.md`). Range 2-1,000. It counts accounts, per group, per
community and per channel. No protocol change: the server only counts
memberships, and MLS group size is bounded by leaves (devices, up to 10 per
account), not by this number.

## Steps

| Step | Default | Needs | Evidence |
|---|---:|---|---|
| 0 | 100 | D38 | tier S |
| 1 | 250 | nothing else: 2 x (1 + 250) = 502 is under the default 1,000 deliveries a minute | `testing/evidence/C8-bigger-communities.md`; 250 members at 2 devices is 500 leaves, inside the C0 measurements (200 and 1,000 leaves) |
| 2 | 500 | `DELIVERIES_PER_MINUTE` of at least 1,002 (startup refuses less), so the default of both settings changes together; a measured fan-out run through `scripts/capacity.sh c8` with a 500-member group on the owner's host; 1,000 leaves is the C0 limit at 2 devices | container numbers only (2026-11-21, no cost growth from 250 to 500, not qualifying); owner-host run open |
| 3 | 1,000 | deliveries of at least 2,002; MLS at up to 2,000 leaves (no measurement above 1,000); C1 chunked adds | not yet |

A step is taken when its evidence file section exists and passes. Instances
can already set any value in the range by hand; steps change the default.

## Known limits

- **Worst-case devices.** 250 members with 10 devices each is 2,500 leaves,
  above anything measured. Typical use is 1-3 devices.
- **Commit batch.** The native layer refuses more than 256 adds or removes in
  one commit (`MAX_MEMBERSHIP_CHANGES`, `crypto/rust/src/ffi.rs`). A bulk
  build of a group above that needs several commits; that belongs to the C1
  join flow, not to this package.
- **Delivery budget.** A sender in a full 250-member group may post about 4
  messages a minute at the default budget. Busy communities raise
  `DELIVERIES_PER_MINUTE`.
- **Cold-tree removals** at 1,000 leaves cost about 83 KB per commit to every
  device (C0 evidence); the C0 self-update rule keeps them down.

- **Seeding cost.** A group above 100 is finished through the member route,
  one write each. A write is admitted only with a balance of `1 + limit`
  deliveries and is charged `1 +` its recipients, and an add reaches every
  current member, so adding 400 members costs about 120,000 deliveries: about
  two hours at the 1,002 floor for one account. A real community of 500 is
  built over time (or by several admins); the capacity run raises the budget
  for seeding. Owner question 2 (scale the budget with the limit) is the
  same issue seen from the other side.
- **Creation cap.** Creating a conversation names at most 100 other
  accounts.

## Owner questions

1. Is raising the default (rather than leaving 100 and documenting the
   variable) wanted as D38 changes? Step 1 raises it to 250.
2. Should the delivery budget scale automatically with the member limit
   instead of being a separate setting?
3. Should step 2 wait for a real 500-member capacity run on the owner's host?

## Owner decisions (2026-11-01)

- Default member limit 250 approved.
