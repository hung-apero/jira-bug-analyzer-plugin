# Auto ticket-pick — tiêu chí pick ticket dưới `--auto` (Phase 1)

> `[AUTO]` decision file cho **Phase 1 pick**. Dưới `--auto` dev không pick tay — file này là
> tiêu chí auto pick. Query + group list vẫn do **Pull & list by category**
> (`references/phase1-init-multi-mode-without-team.md`) lo; file này chỉ thay phần *pick*.
> Rubric anh em: `auto-plan-pick.md` (Phase 3), `auto-run-test.md` (Phase 5).

## Tiêu chí pick
- **Tối đa 3 ticket / lượt.** Dư thì để lượt sau (re-pull).
- **Sắp theo priority bug cao → thấp**, pick từ trên xuống.
- **Ưu tiên ticket CHƯA assign cho người khác** trước (unassigned / assign cho mình); ticket đang
  assign người khác xếp sau.
- **Lặp từng lượt:** pick → fix → re-pull → pick 3 cái tiếp theo → … đến khi board rỗng thì STOP.

## Bỏ qua (không pick)
- `[CLAIM]` claim fail (người khác đang giữ) → bỏ.
- Trùng `root_cause_slug` với ticket đang/đã fix (`record_bug_status.md`) → bỏ, ghi chú ticket gốc.
- Đã `done`/`commented`/`deferred`/`blocked-auto` trong `.jira-bug/batch-progress.md` → bỏ.
- **Ledger (`record_bug_status.md`) có row `analyzed-deferred` cho ĐÚNG ticket này → BỎ** (đã phân tích + defer lần trước, đang chờ blocker được giải / clarify được trả lời). Đây là cơ chế chống re-pick khi defer→`Request` đưa ticket trở lại pool (xem `auto-plan-pick.md` → "Khi defer"). **NGOẠI LỆ — pick lại** khi ticket được reopen KÈM thông tin MỚI sau ngày defer (comment/attachment mới muộn hơn `date` của ledger row, hoặc dev nói rõ blocker đã hết): coi như có context mới → re-analyze với thông tin đó.

## Single mode
Không áp dụng — ticket đã cho sẵn theo key. Bỏ qua file này, sang thẳng `auto-plan-pick.md`.
