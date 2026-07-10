# Auto plan-pick — tiêu chí fix vs defer dưới `--auto` (Phase 3)

> `[AUTO]` decision file cho **Phase 3 approval**. Dưới `--auto` không hỏi dev — file này là tiêu
> chí tự quyết **fix luôn vs defer + report**, dựa trên scorecard. **Dùng** điểm từ
> `references/helpers/confidence-rubric.md` (không định nghĩa lại cách chấm).
> Rubric anh em: `auto-ticket-pick.md` (Phase 1), `auto-run-test.md` (Phase 5).

## Tiêu chí quyết định
- **Score `sum ≥ 80`** → auto-approve → fix luôn (Phase 4).
- **Không reproduce được on-device** (`bug-analysis-rules.md` `[REPRO]` A7a/A10) → **defer** (`unreproducible` hoặc `no-device`); **dưới `--auto` device là BẮT BUỘC, không có static fallback** — không có máy / không lấy được device lock trong thời gian chờ / chạy hết ladder vẫn không repro → defer + report. `--auto` KHÔNG BAO GIỜ auto-fix một bug chưa reproduce được trên máy.
- **Không phải bug code thật** (config/console · backend · stale build/env/device · works-as-designed · duplicate — A1/A2) → route Fix-9 (non-code comment) / defer; không tự chế fix.
- **Score `sum < 80`** → **defer + report** (mark `deferred`, không fix), ghi lý do `score <80 (sum=N)`.
- **Còn câu hỏi chưa rõ** (SOT/spec/figma không trả lời được) → **defer** (`clarify-gap`); auto KHÔNG tự đoán.
- **Mid-fix phát hiện plan sai** → **defer** (`mid-fix wrong-plan`); không auto re-plan.
- **Trùng** `root_cause_slug` ticket khác → **skip** (mark `commented`, ghi ticket gốc); không "fix anyway".

## Khi defer — chuyển sang "Request" rồi ĐI TIẾP (không dừng loop)
Mỗi khi một ticket bị defer (score <80 / clarify-gap / mid-fix wrong-plan / **unreproducible / no-device**), dưới `--auto`:
1. **Transition ticket → `Request`** (REST, `jira_transition`) — đưa nó RA KHỎI `In Progress` và trả về pool triage mở để người (hoặc một lần chạy sau có thêm thông tin) tiếp nhận. **Giữ assignee = dev account** (người đã claim) để biết ai đã phân tích. Verify `now=Request` qua readback. (Nếu workflow không có transition tên `Request`, dùng status mở gần nhất; nếu thực sự không thoát được `In Progress` thì để nguyên + ghi chú trong report.)
2. Post 1 comment `[VN]` ngắn lên ticket: lý do defer + tóm tắt plan đã có (để người sau làm tiếp), kèm link ledger slug. (`[REST]`, verify 201.)
3. Giữ nguyên ledger row `analyzed-deferred` (root_cause_slug + summary + files) + thêm vào end-of-run report.
4. **ĐI TIẾP NGAY sang ticket/batch kế** — **defer KHÔNG BAO GIỜ là điều kiện dừng loop.** Loop chỉ dừng khi re-pull trả về 0 ticket (board rỗng) hoặc gặp `[AUTO-GATE]` do dev định nghĩa. **Vì `Request` NẰM TRONG pool pull, chống re-pick KHÔNG dựa vào status mà dựa vào DEDUP:** `.jira-bug/batch-progress.md` (cùng session) + ledger row `analyzed-deferred` (cross-session). `auto-ticket-pick.md` BỎ QUA mọi ticket đã `analyzed-deferred`, TRỪ khi ticket được reopen kèm thông tin mới (comment/attachment mới sau ngày defer = clarify đã được trả lời) — khi đó re-pick + re-analyze với context mới là ĐÚNG ý đồ (defer→Request = "trả về hàng đợi, sẽ xử lý khi hết blocker"). Nhờ vậy re-pull vẫn tiến tới ticket MỚI thay vì lặp vô hạn mấy ticket defer.

> **Base build hỏng (vd `origin/develop` không compile) KHÔNG phải lý do dừng** — đây là case "try-and-decide" của Golden Rule `[AUTO]`: fold bản unbreak tối thiểu vào nhánh fix hiện tại (hoặc branch các fix kế off nhánh batch đã chứa unbreak), ghi vào report, đi tiếp. Đừng pause loop chờ người.

## Single mode
Cùng tiêu chí cho 1 ticket: ≥80 → fix; <80 / clarify-gap → defer + report. Defer cũng PARK sang `To Do` như trên (single thì park xong là kết thúc, không có batch kế).
