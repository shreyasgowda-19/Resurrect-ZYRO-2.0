# T4-F manual browser integration checks

Run these against the authenticated T4 demo backend using separate planner and approver Firebase accounts. Use only demonstration records; no real supplier contact or external purchasing is part of this workflow.

## Planner proposal workflow

1. Sign in as a planner and open an at-risk, critical, or delayed order.
2. Generate recommendations, then simulate one option. Confirm the card shows backend evidence, assumptions, the hypothetical before/after result, delivery impact, and collateral order outcomes.
3. Select **Submit for Approval**. In browser Network, verify one authenticated `POST /proposals` with `order_id`, `recommendation_id`, and the displayed current `expected_version`.
4. Double-click while the request is pending. Confirm only one POST is sent and a success or duplicate message appears.
5. Open **Approvals** and confirm the proposal, original version, evidence, assumptions, and simulation appear from `GET /proposals`.
6. Confirm planner controls do not include Approve or Reject.

## Approver decisions

1. Sign in as a different approver UID and open the pending proposal.
2. Try approval with an empty reason and without acknowledging demonstration assumptions. Confirm the action remains disabled.
3. Enter a reason, acknowledge assumptions, and confirm the approval dialog. Verify `POST /proposals/{proposal_id}/decision` includes a 32-character lowercase hexadecimal `decision_id`, `decision: approve`, the current version, the exact reason, and `acknowledge_demo_assumptions: true`.
4. For a rejection, verify a nonempty reason is required and acknowledgment is not required.
5. Open a proposal created by the signed-in approver UID. Confirm self-approval is unavailable.
6. Simulate an uncertain response (for example, interrupt the response after dispatch) and retry. Confirm the retry sends the identical request body and decision ID.

## Versioning and records

1. Create a pending proposal, then advance the demo snapshot using an authorized demonstration event from another planner session. Confirm polling marks the proposal outdated and disables approval.
2. Cause a decision to receive HTTP 409. Confirm the state and proposal list refresh, and the old decision is not automatically retried.
3. Approve one `alternate_supplier_po` demonstration proposal in the test backend. Confirm only the backend-returned demo PO and incoming record appear, physical on-hand stock is not represented as locally changed, and the UI labels the PO as demo-only.
4. Approve one `expedite_existing_lot` demonstration proposal. Confirm it displays “awaiting supplier confirmation” and projected delivery dates do not change until the backend reports a supplier confirmation.
5. Confirm persistent audit entries show action, actor role, timestamp, proposal ID, and version for submitted, approved, rejected, PO-created, and expedite-authorized actions as applicable.

## Responsive check

At laptop width and a 390 px mobile viewport, inspect the proposal cards, dialogs, purchase orders, and audit timeline. Confirm the page scrolls vertically, cards stack on mobile, and no content overflows horizontally or vertically.
