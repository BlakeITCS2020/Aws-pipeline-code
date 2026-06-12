# Hướng Dẫn Đọc Chỉ Số Dashboard Nash DataOps

Tài liệu này giải thích cách đọc các dashboard Metabase được tạo bởi
`import-demo-dashboards.py`.

## Đối Tượng Sử Dụng

Sử dụng các dashboard này để giải thích giá trị của luồng DataOps:

- File dữ liệu thô được đưa vào S3 Bronze.
- Glue biến đổi và chuẩn hóa dữ liệu sang Silver.
- Glue Data Quality chặn dữ liệu Silver không đạt chất lượng trước khi dữ liệu
  đi vào warehouse.
- Redshift lưu một mô hình star schema nhỏ phục vụ phân tích nghiệp vụ.
- Metabase biến các bảng trong warehouse thành insight sẵn sàng để trình bày.

## Dashboard 1: Executive Overview

Sử dụng dashboard này đầu tiên. Dashboard này trả lời câu hỏi: pipeline đã tạo
ra dữ liệu nghiệp vụ có ích và có thể truy vấn được chưa?

### Total trips loaded

Ý nghĩa: tổng số dòng trong `nyc_taxi.fact_fhvhv_trips`.

Cách đọc: đây là volume dữ liệu đã được load vào warehouse bởi lần chạy
pipeline thành công gần nhất. Trong demo hiện tại, con số này nên khoảng
`2.46M` chuyến đi.

Ghi chú trình bày: đây là bằng chứng nhanh nhất cho thấy pipeline đã xử lý một
bộ dữ liệu công khai lớn từ đầu đến cuối.

### Average trip duration

Ý nghĩa: giá trị trung bình của `trip_duration_minutes` sau bộ lọc chất lượng ở
lớp Silver.

Cách đọc: con số này nên hợp lý với các chuyến đi kiểu taxi. Các outlier quá
lớn đã được lọc trước khi dữ liệu đi vào Redshift.

Ghi chú trình bày: chỉ số này kết nối trực tiếp chất lượng dữ liệu với chất
lượng dashboard. Dashboard không chỉ visualize dữ liệu thô; nó visualize dữ
liệu đã được curated.

### Pickup location coverage

Ý nghĩa: tỷ lệ phần trăm chuyến đi có pickup location ID không null.

Cách đọc: nguồn dữ liệu công khai này có pickup location khá thưa, nên tỷ lệ này
dự kiến thấp hơn nhiều so với dropoff coverage. Pickup coverage thấp không phải
là lỗi pipeline; đó là thực tế của source data được thể hiện minh bạch.

Ghi chú trình bày: đây là thời điểm tốt để giải thích rằng Data Quality rules
nên phù hợp với đặc điểm của source dataset, thay vì yêu cầu mọi field phải
complete một cách máy móc.

### Dropoff location coverage

Ý nghĩa: tỷ lệ phần trăm chuyến đi có dropoff location ID không null.

Cách đọc: tỷ lệ này nên đủ cao để hỗ trợ phần lớn phân tích route và zone.

Ghi chú trình bày: so sánh chỉ số này với pickup coverage để cho thấy quality
gate kiểm tra từng field dựa trên hành vi thực tế của source data.

### Daily trip volume

Ý nghĩa: số chuyến đi được group theo pickup date.

Cách đọc: dùng chart này để nhận diện pattern nhu cầu, ngày bị thiếu, và các
điểm tăng/giảm bất thường. Một chart bình thường cho thấy date dimension và fact
table đang hoạt động cùng nhau.

Ghi chú trình bày: đây là chart chính để nói về xu hướng nghiệp vụ.

### Trips by pickup borough

Ý nghĩa: số chuyến đi được group theo pickup borough sau khi join fact rows với
`dim_zone`.

Cách đọc: `Unknown` nghĩa là pickup location bị thiếu hoặc không map được với
zone đã biết. Với dataset công khai này, `Unknown` có thể xuất hiện nổi bật.

Ghi chú trình bày: hãy giữ `Unknown` hiển thị. Ẩn nó sẽ làm dashboard trông sạch
hơn, nhưng kém trung thực hơn.

### Trips by pickup hour

Ý nghĩa: số chuyến đi được group theo giờ trong ngày.

Cách đọc: các giờ cao điểm cho thấy nhu cầu tập trung vào thời điểm nào. Chart
này hữu ích cho thảo luận về vận hành, phân bổ nhân sự hoặc capacity.

Ghi chú trình bày: chart này cho thấy pipeline đã giữ lại các field thời gian
hữu ích, không chỉ giữ date.

### Warehouse table counts

Ý nghĩa: số dòng của `fact_fhvhv_trips`, `dim_date`, và `dim_zone`.

Cách đọc: đây là một health check gọn cho star schema. Fact table nên lớn, trong
khi các dimension table nên nhỏ và ổn định.

Ghi chú trình bày: dùng chỉ số này để chuyển từ câu chuyện pipeline sang câu
chuyện data model.

## Dashboard 2: Zone & Route Analysis

Sử dụng dashboard này thứ hai. Dashboard này trả lời câu hỏi: đội vận hành có
thể học được gì từ warehouse?

### Top pickup zones and top dropoff zones

Ý nghĩa: các pickup zone và dropoff zone đã map được có volume cao nhất.

Cách đọc: các chart này tập trung vào location đã map được. Chúng cố ý loại bỏ
pickup/dropoff ID null ở những nơi phù hợp để chart xếp hạng các zone thật.

Ghi chú trình bày: đây là nơi dimensional model trở nên dễ thấy: location ID từ
fact được enrich bằng borough, zone và service-zone label.

### Borough-to-borough flows

Ý nghĩa: volume chuyến đi và thời lượng trung bình theo pickup borough và
dropoff borough.

Cách đọc: trip count cao cho biết các luồng di chuyển chính. Average duration
bổ sung thêm ngữ cảnh vận hành.

Ghi chú trình bày: bảng này hữu ích để giải thích phân tích cấp route mà không
làm audience bị quá tải bởi tất cả cặp zone.

### Top pickup-to-dropoff routes

Ý nghĩa: các route zone-to-zone đã biết có tần suất cao nhất.

Cách đọc: route có count cao đại diện cho các hành lang nhu cầu ổn định.

Ghi chú trình bày: đây là output hướng nghiệp vụ rõ nhất từ lớp Gold warehouse.

### Longest common routes

Ý nghĩa: các route có volume cao được sắp xếp theo average duration.

Cách đọc: chỉ số này tránh các chuyến đi cực đoan đơn lẻ bằng cách yêu cầu ít
nhất 100 chuyến mỗi route, sau đó highlight các route có thời gian di chuyển
dài hơn.

Ghi chú trình bày: đây là metric vận hành có nhận thức về chất lượng dữ liệu vì
nó tránh bị đánh lừa bởi route có sample quá nhỏ.

### Trips by pickup service zone

Ý nghĩa: volume chuyến đi theo category service-zone của TLC.

Cách đọc: chỉ số này giúp tóm tắt nhu cầu ở cấp địa lý rộng hơn individual
zone.

Ghi chú trình bày: dùng chart này khi các chart cấp zone có quá nhiều chi tiết
đối với audience.

## Dashboard 3: Pipeline Proof

Sử dụng dashboard này cuối cùng hoặc như phần phụ lục. Dashboard này trả lời câu
hỏi: chúng ta có thể tin pipeline và giải thích dữ liệu đến từ đâu không?

### Loaded date range

Ý nghĩa: pickup date đầu tiên, pickup date cuối cùng, và số ngày pickup khác
nhau trong warehouse.

Cách đọc: xác nhận chính xác khoảng thời gian mà dữ liệu demo bao phủ.

Ghi chú trình bày: dùng chỉ số này để tránh các tuyên bố mơ hồ như "dữ liệu gần
đây" hoặc "một ít sample data". Hãy nói cụ thể.

### Loaded run IDs

Ý nghĩa: số dòng được group theo pipeline run ID.

Cách đọc: cho thấy pipeline run nào đã tạo ra các dòng trong warehouse.

Ghi chú trình bày: chỉ số này hỗ trợ khả năng traceability trong DataOps
closed-loop.

### Loaded source files

Ý nghĩa: fact rows được group theo source file.

Cách đọc: xác nhận lineage ở cấp source file vẫn được giữ sau transformation và
load.

Ghi chú trình bày: chỉ số này hữu ích khi giải thích khả năng audit.

### Duration quality band

Ý nghĩa: min, average, và max trip duration sau quality filtering.

Cách đọc: max duration nên nằm dưới threshold chất lượng Silver đã cấu hình.
Trong demo này, ETL lọc trip duration nhỏ hơn 1440 phút.

Ghi chú trình bày: chỉ số này chứng minh quality rule có tác động quan sát được
trong warehouse.

### Location completeness profile

Ý nghĩa: non-null counts và completeness percentage cho pickup và dropoff
location IDs.

Cách đọc: so sánh các con số này với threshold của Glue Data Quality. Dashboard
nên làm rõ cùng một tradeoff về chất lượng dữ liệu cho business users.

Ghi chú trình bày: đây là nơi bạn giải thích rằng data quality không chỉ là
pass hoặc fail; nó là một contract rõ ràng.

## Luồng Demo Được Khuyến Nghị

1. Bắt đầu với `Executive Overview`.
2. Hiển thị total trips loaded và table counts để chứng minh pipeline đã hoàn
   tất.
3. Chuyển sang daily volume và pickup hour để cho thấy giá trị nghiệp vụ.
4. Mở `Zone & Route Analysis` để cho thấy dimensional analytics.
5. Kết thúc với `Pipeline Proof` để giải thích quality, lineage và traceability.

## Quy Tắc Đọc Dashboard

- Xem `Unknown` là sự minh bạch của source data, không phải lỗi dashboard.
- Không so sánh pickup coverage và dropoff coverage như thể chúng bắt buộc phải
  bằng nhau; source có đặc điểm completeness khác nhau cho từng field.
- Dùng row counts cùng với quality metrics. Row count lớn không tự chứng minh dữ
  liệu đáng tin cậy.
- Ưu tiên route metrics có volume threshold khi thảo luận về duration; điều này
  tránh diễn giải quá mức các route có sample thấp.

## Tiêu Chí Dashboard Chuyên Nghiệp

Các dashboard được import tuân theo các nguyên tắc sau:

- KPI xuất hiện đầu tiên, trước các bảng chi tiết.
- Mỗi operational chart có dimension và metric rõ ràng.
- Quality và lineage được tách riêng vào một proof dashboard.
- Giá trị null hoặc unknown được hiển thị rõ ràng thay vì bị loại bỏ âm thầm.
- Layout dùng section headings để presenter có thể đi qua câu chuyện theo thứ
  tự dễ dự đoán.
