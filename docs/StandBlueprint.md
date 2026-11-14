# Dựng một level Farm Stand mới

Mọi vị trí của stand lấy từ **marker**. Code không chứa Vector3 nào cho stand.
Tên và số lượng marker nằm trong `src/shared/StandLayoutConfig.luau`.

## Cấu trúc

```
ServerStorage.StandModels.FarmStand.Level<N>   (Model, PrimaryPart = Body.Base)
  Body      phần nhìn thấy: các "Stall" là bản copy của shop Sell (Plot1.Shops.Sell)
    Base    sàn; LookVector (-Z) = phía khách; tâm sàn = điểm pivot
  Pads      KeeperPad_N (bản copy pad Worker, thu nhỏ 0.8), pad Upgrade xanh lá, thảm RESTOCK
  Markers   Part ẩn (1.6 x 0.2 x 1.6), tên theo quy ước

Workspace.Plots.<Plot>.StandSites.FarmStand    (site trên plot, giống nhau mọi level)
  Anchor    level model được PivotTo vào đây
  Plaza     nền gạch dưới khu stand
  HelperRamp  dốc cho helper đi từ plot xuống sau stand
  Pads      HelperPad_1..3 cạnh TreasureChest (bản copy pad Worker)
  Markers   HelperSlot_1..3, HelperPickupPoint, HelperPath_N, CustomerSpawn_N, CustomerPath_N, CustomerExit_N

ServerStorage.StandModels.HeroPadTemplate      pad mẫu (copy từ HeroSlots.Slot1) cho Keeper / Helper
```

## Thêm level 6 (ví dụ)

1. Duplicate `Level5`, đổi tên thành `Level6`, sửa phần `Body`. Nhớ giữ `Base` làm PrimaryPart.
2. Thêm/xóa marker trong `Markers` (tên theo bảng ở đầu `StandLayoutConfig.luau`, ví dụ `ServePoint_7`, `QueuePoint_17`).
3. Thêm entry thứ 6 vào `StandLayoutConfig.Stands.FarmStand.Levels`, ghi đúng số marker và Footprint.
4. Chạy lệnh dưới trên command bar và sửa đến khi báo OK:
   ```lua
   require(game.ServerScriptService.Server.StandLayoutDebug).Check()
   ```
5. Xem trước level với marker, nhãn và đường đi:
   ```lua
   require(game.ServerScriptService.Server.StandLayoutDebug).Preview(6)
   ```
   Ẩn marker bằng `.Show(false)`, gỡ stand xem trước bằng `.Clear()`.

## Dựng lại blockout

Script `tools/stand/BuildStandBlockouts.luau` dựng lại toàn bộ 5 level (từ shop Sell), site, pad và con đường từ đầu.
Script này ghi đè những gì đã chỉnh tay, nên chỉ dùng khi muốn reset.
Rojo sync script vào `ServerStorage.StandTools` (sau khi restart `rojo serve`):
```lua
require(game.ServerStorage.StandTools.BuildStandBlockouts).All(workspace.Plots.Plot1)
```

## Quy tắc Check kiểm tra
- Đủ marker theo config, không trùng tên, không có tên lạ (gõ sai).
- Không thừa marker đánh số so với config.
- Pad cách nhau ≥ `MinPadSpacing`, ServePoint ≥ `MinServeSpacing`, QueuePoint ≥ `MinQueueSpacing`.
- `Body` nằm trong Footprint của level.
