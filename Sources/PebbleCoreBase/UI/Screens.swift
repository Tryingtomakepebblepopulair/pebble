// Gameplay screens — inventory, crafting, furnace,
// chest, brewing, enchanting, anvil, grindstone, stonecutter, smithing,
// beacon, trading, creative, sign, death, chat. Same layouts and slot logic.

import Foundation

// =============================================================================
// Base container screen with player inventory
// =============================================================================
open class ContainerScreen: Screen {
    open var panelX = 0.0
    open var panelY = 0.0
    open var panelW = 176.0
    open var panelH = 166.0
    open var title = ""
    open var titleX = 8.0              // panel-local title position (vanilla titleLabelX/Y)
    open var titleY = 6.0
    open var showInvLabel = true       // vanilla hides "Inventory" on the survival inventory
    open var sheet: String?            // pack GUI container texture key (nil = procedural panel)
    open var playerSlots: [SlotDef] = []
    open var containerSlots: [SlotDef] = []
    /// y of the player inventory slot grid, panel-local (vanilla: imageHeight−83/−84)
    open var playerInvY: Double { panelH - 83 }
    /// true when this frame's panel came from the pack texture (slot bgs baked in)
    private(set) var textured = false

    open override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - panelW) / 2).rounded(.down)
        panelY = ((ui.height - panelH) / 2).rounded(.down)
        playerSlots = playerInvSlots(game.player, panelX + 7, panelY + playerInvY)
        buildSlots(ui, game)
        slots = containerSlots + playerSlots
    }
    open func buildSlots(_ ui: UIManager, _ game: GameCore) {}

    /// draw the panel from the pack sheet; subclasses override for multi-piece blits
    open func drawSheetPanel(_ ui: UIManager) -> Bool {
        guard let sheet else { return false }
        return ui.blitSheet(sheet, 0, 0, panelW, panelH, panelX, panelY)
    }

    open override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        textured = drawSheetPanel(ui)
        if !textured { ui.drawPanel(panelX, panelY, panelW, panelH) }
        ui.cv.drawText(title, panelX + titleX, panelY + titleY, 1, "#3f3f3f", shadow: false)
        if showInvLabel {
            ui.cv.drawText("Inventory", panelX + 8, panelY + playerInvY - 10, 1, "#3f3f3f", shadow: false)
        }
        drawExtra(ui, game)
        ui.drawSlots(self, slotBg: !textured)
        ui.drawButtons(self)
    }
    open func drawExtra(_ ui: UIManager, _ game: GameCore) {}

    open override func quickMove(_ game: GameCore, _ slot: SlotDef) {
        guard let s = slot.get() else { return }
        let fromContainer = containerSlots.contains { $0 === slot }
        let targets = fromContainer ? playerSlots : containerSlots.filter { !$0.output }
        if quickMoveInto(s, targets) {
            if s.count <= 0 { slot.set(nil) }
        }
        if s.count <= 0 { slot.set(nil) }
        slot.onChange?()
    }
}

// =============================================================================
// Inventory (survival) — 2×2 crafting + armor + offhand
// =============================================================================
public final class InventoryScreen: ContainerScreen {
    public var craftGrid: [ItemStack?] = [nil, nil, nil, nil]
    public var craftResult: ItemStack?

    public override init() {
        super.init()
        title = "Crafting"
        titleX = 97
        titleY = 8
        showInvLabel = false
        sheet = "inventory"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let p = game.player!
        let px = panelX, py = panelY
        for i in 0..<4 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 7, y: py + 7 + Double(i) * 18,
                get: { p.armor[idx] },
                set: { p.armor[idx] = $0 },
                canPlace: { itemDef($0.id).armor?.slot == idx }))
        }
        containerSlots.append(SlotDef(
            x: px + 76, y: py + 61,
            get: { p.offHand },
            set: { p.offHand = $0 }))
        for i in 0..<4 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 97 + Double(i % 2) * 18, y: py + 18 + Double(i / 2) * 18,
                get: { [weak self] in self?.craftGrid[idx] },
                set: { [weak self] s in
                    self?.craftGrid[idx] = s
                    self?.updateResult()
                },
                onChange: { [weak self] in self?.updateResult() }))
        }
        containerSlots.append(SlotDef(
            x: px + 153, y: py + 27,
            get: { [weak self] in self?.craftResult },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self else { return }
                _ = consumeCraftingGrid(&self.craftGrid)
                self.updateResult()
                game?.advance("craft_any")
            }))
    }
    public func updateResult() {
        craftResult = matchCrafting(craftGrid, 2, 2)?.out
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        // vanilla inventory.png bakes the preview window, slot art and arrow in;
        // procedurally we draw the window frame + arrow ourselves
        if !textured {
            cv.drawText("▶", panelX + 138, panelY + 31, 1, "#3f3f3f", shadow: false)
            cv.setFill("#1c1c1c")
            cv.fillRect(panelX + 26, panelY + 8, 49, 70)
        }
        // simple front-facing player figure centered in the preview window
        let cx = panelX + 50, by = panelY + 10
        let sway = Foundation.sin(uiNow() * 1000 / 600) * 1.5
        let p = game.player!
        func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: String) {
            cv.setFill(c)
            cv.fillRect((cx + x + (y < 20 ? sway : 0)).rounded(), by + 6 + y, w, h)
        }
        px(-6, 0, 12, 12, "#b88a64")
        px(-4, 3, 3, 3, "#ffffff"); px(1, 3, 3, 3, "#ffffff")
        px(-3, 4, 2, 2, "#3a6ea8"); px(2, 4, 2, 2, "#3a6ea8")
        px(-6, 0, 12, 4, "#5a3c28")
        px(-6, 13, 12, 18, p.armor[1] != nil ? "#c8c8d0" : "#2ea3a3")
        px(-11, 13, 5, 16, "#b88a64")
        px(6, 13, 5, 16, "#b88a64")
        px(-6, 31, 5, 18, p.armor[2] != nil ? "#a8a8b0" : "#3a3a8c")
        px(1, 31, 5, 18, p.armor[2] != nil ? "#a8a8b0" : "#3a3a8c")
        px(-6, 49, 5, 4, p.armor[3] != nil ? "#909098" : "#6a6a6a")
        px(1, 49, 5, 4, p.armor[3] != nil ? "#909098" : "#6a6a6a")
        if p.armor[0] != nil { px(-6, 0, 12, 5, "#c8c8d0") }
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        for i in 0..<4 {
            if let s = craftGrid[i] {
                _ = game.player.give(s)
                craftGrid[i] = nil
            }
        }
    }
}

// =============================================================================
// Crafting table 3×3
// =============================================================================
public final class CraftingScreen: ContainerScreen {
    public var craftGrid: [ItemStack?] = Array(repeating: nil, count: 9)
    public var craftResult: ItemStack?

    public override init() {
        super.init()
        title = "Crafting"
        titleX = 29
        sheet = "crafting_table"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        for i in 0..<9 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 29 + Double(i % 3) * 18, y: py + 16 + Double(i / 3) * 18,
                get: { [weak self] in self?.craftGrid[idx] },
                set: { [weak self] s in
                    self?.craftGrid[idx] = s
                    self?.updateResult()
                },
                onChange: { [weak self] in self?.updateResult() }))
        }
        containerSlots.append(SlotDef(
            x: px + 123, y: py + 34,
            get: { [weak self] in self?.craftResult },
            set: { _ in },
            output: true,
            onTake: { [weak self] _ in
                guard let self else { return }
                _ = consumeCraftingGrid(&self.craftGrid)
                self.updateResult()
            }))
    }
    public func updateResult() {
        craftResult = matchCrafting(craftGrid, 3, 3)?.out
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if !textured {
            ui.cv.drawText("▶", panelX + 95, panelY + 38, 2, "#3f3f3f", shadow: false)
        }
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        for i in 0..<9 {
            if let s = craftGrid[i] {
                _ = game.player.give(s)
                craftGrid[i] = nil
            }
        }
    }
}

// =============================================================================
// Furnace / blast furnace / smoker
// =============================================================================
public final class FurnaceScreen: ContainerScreen {
    private let be: BlockEntityData

    public init(_ be: BlockEntityData) {
        self.be = be
        super.init()
        title = be.kind == "blast" ? "Blast Furnace" : be.kind == "smoker" ? "Smoker" : "Furnace"
        sheet = "furnace"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        let be = self.be
        containerSlots.append(SlotDef(
            x: px + 55, y: py + 16,
            get: { be.items![0] }, set: { be.items![0] = $0 }))
        containerSlots.append(SlotDef(
            x: px + 55, y: py + 52,
            get: { be.items![1] }, set: { be.items![1] = $0 },
            canPlace: { fuelTime($0) > 0 }))
        containerSlots.append(SlotDef(
            x: px + 115, y: py + 34,
            get: { be.items![2] },
            set: { _ in },
            output: true,
            onTake: { [weak game] _ in
                be.items![2] = nil
                let xp = Int(be.xpBank ?? 0)
                if xp > 0, let game {
                    spawnXP(game.world, game.player.x, game.player.y, game.player.z, xp)
                    be.xpBank = 0
                }
            }))
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        let px = panelX, py = panelY
        let burnTime = be.burnTime ?? 0
        let burnF = (be.burnTotal ?? 0) > 0 ? Double(burnTime) / Double(be.burnTotal!) : 0
        let prog = (be.cookTotal ?? 0) > 0 ? Double(be.cookTime ?? 0) / Double(be.cookTotal!) : 0
        if textured {
            // vanilla overlays from furnace.png: flame (176,0) fills bottom-up,
            // arrow (176,14) fills left-to-right
            if burnTime > 0 {
                let i = (burnF * 13).rounded()
                ui.blitSheet("furnace", 176, 12 - i, 14, i + 1, px + 56, py + 36 + 12 - i)
            }
            let j = (prog * 24).rounded()
            if j > 0 {
                ui.blitSheet("furnace", 176, 14, j + 1, 16, px + 79, py + 34)
            }
            return
        }
        if burnTime > 0 {
            let h = (burnF * 13).rounded(.up)
            cv.setFill("#ff9a2c")
            cv.fillRect(px + 57, py + 36 + (13 - h), 13, h)
        } else {
            cv.setFill("#3a3a3a")
            cv.fillRect(px + 57, py + 36, 13, 13)
        }
        cv.setFill("#5a5a5a")
        cv.fillRect(px + 79, py + 38, 24, 10)
        cv.setFill("#ffffff")
        cv.fillRect(px + 79, py + 38, (24 * prog).rounded(), 10)
    }
}

// =============================================================================
// Generic chest-style container
// =============================================================================
public final class ChestScreen: ContainerScreen {
    private let getItems: () -> [ItemStack?]
    private let setItem: (Int, ItemStack?) -> Void
    private let count: Int
    private let other: BlockEntityData?

    /// items live in a BlockEntityData or a vehicle — accessors close over the owner
    public init(_ be: BlockEntityData, _ title: String, _ other: BlockEntityData? = nil) {
        count = be.items?.count ?? 27
        getItems = { be.items ?? [] }
        setItem = { be.items?[$0] = $1 }
        self.other = other
        super.init()
        self.title = title
        let total = count + (other?.items?.count ?? 0)
        panelH = 114 + Double((total + 8) / 9) * 18
    }
    public init(vehicle: Boat, _ title: String) {
        count = vehicle.chestItems.count
        getItems = { vehicle.chestItems }
        setItem = { vehicle.chestItems[$0] = $1 }
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }
    public init(vehicle: Minecart, _ title: String) {
        count = vehicle.chestItems.count
        getItems = { vehicle.chestItems }
        setItem = { vehicle.chestItems[$0] = $1 }
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }
    public init(items: @escaping () -> [ItemStack?], set: @escaping (Int, ItemStack?) -> Void, count: Int, _ title: String) {
        self.count = count
        getItems = items
        setItem = set
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }

    /// vanilla generic_54 player grid sits at imageHeight−84 (one px above the 166-panel layouts)
    public override var playerInvY: Double { panelH - 84 }

    /// generic_54.png is sliced vanilla-style: header+rows piece, then the
    /// player-inventory piece from y=126 — works for any 1–6 row container
    public override func drawSheetPanel(_ ui: UIManager) -> Bool {
        let rows = (panelH - 114) / 18
        let total = containerSlots.count
        guard total % 9 == 0, rows >= 1, rows <= 6, ui.hasSheet("generic_54") else { return false }
        let topH = rows * 18 + 17
        ui.blitSheet("generic_54", 0, 0, 176, topH, panelX, panelY)
        ui.blitSheet("generic_54", 0, 126, 176, 96, panelX, panelY + topH)
        return true
    }

    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        var i = 0
        for idx in 0..<count {
            let g = getItems, s = setItem
            containerSlots.append(SlotDef(
                x: px + 7 + Double(i % 9) * 18,
                y: py + 17 + Double(i / 9) * 18,
                get: { g()[idx] },
                set: { s(idx, $0) }))
            i += 1
        }
        if let o = other, o.items != nil {
            for idx in 0..<(o.items!.count) {
                containerSlots.append(SlotDef(
                    x: px + 7 + Double(i % 9) * 18,
                    y: py + 17 + Double(i / 9) * 18,
                    get: { o.items![idx] },
                    set: { o.items![idx] = $0 }))
                i += 1
            }
        }
    }
}

// =============================================================================
// Brewing stand
// =============================================================================
public final class BrewingScreen: ContainerScreen {
    private let be: BlockEntityData

    public init(_ be: BlockEntityData) {
        self.be = be
        super.init()
        title = "Brewing Stand"
        sheet = "brewing_stand"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        let be = self.be
        let bottlePositions: [(Double, Double)] = [(55, 50), (79, 57), (103, 50)]
        for i in 0..<3 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + bottlePositions[i].0, y: py + bottlePositions[i].1,
                get: { be.items![idx] }, set: { be.items![idx] = $0 },
                canPlace: { ["potion", "splash_potion", "lingering_potion", "glass_bottle"].contains(itemDef($0.id).name) }))
        }
        containerSlots.append(SlotDef(
            x: px + 78, y: py + 16,
            get: { be.items![3] }, set: { be.items![3] = $0 },
            canPlace: { isBrewIngredient(itemDef($0.id).name) }))
        containerSlots.append(SlotDef(
            x: px + 16, y: py + 16,
            get: { be.items![4] }, set: { be.items![4] = $0 },
            canPlace: { itemDef($0.id).name == "blaze_powder" }))
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        let px = panelX, py = panelY
        let fuelW = (18 * Double(be.fuel ?? 0) / 20).rounded()
        let brewing = (be.brewTime ?? 0) > 0
        let f = brewing ? Double(be.brewTime!) / 400 : 0
        if textured {
            // vanilla overlays from brewing_stand.png: fuel flame strip, brew
            // arrow filling downward, bubbles cycling while active
            if fuelW > 0 { ui.blitSheet("brewing_stand", 176, 29, fuelW, 4, px + 60, py + 44) }
            if brewing {
                let j = (28 * f).rounded()
                if j > 0 { ui.blitSheet("brewing_stand", 176, 0, 9, j, px + 97, py + 16) }
                let lengths: [Double] = [29, 24, 20, 16, 11, 6, 0]
                let k = lengths[Int(uiNow() * 10) % 7]
                if k > 0 { ui.blitSheet("brewing_stand", 185, 29 - k, 12, k, px + 63, py + 14 + 29 - k) }
            }
            return
        }
        cv.setFill("#3a3a3a")
        cv.fillRect(px + 36, py + 18, 18, 4)
        cv.setFill("#e89a3c")
        cv.fillRect(px + 36, py + 18, fuelW, 4)
        if brewing {
            cv.setFill("#e8e8e8")
            cv.fillRect(px + 98, py + 18, 2, (26 * f).rounded())
        }
        cv.drawText("◡", px + 76, py + 36, 1, "#3f3f3f", shadow: false)
    }
}

// =============================================================================
// Enchanting table
// =============================================================================
public final class EnchantingScreen: ContainerScreen {
    public var item: ItemStack?
    public var lapis: ItemStack?
    public var options: [EnchantOption] = []
    public var seed = Int.random(in: 0..<1_000_000_000)
    public var bookshelves = 0
    private let pos: (x: Int, y: Int, z: Int)

    public init(_ pos: (x: Int, y: Int, z: Int)) {
        self.pos = pos
        super.init()
        title = "Enchant"
        sheet = "enchanting_table"
    }
    public override func initScreen(_ ui: UIManager, _ game: GameCore) {
        super.initScreen(ui, game)
        var n = 0
        for dz in -2...2 {
            for dx in -2...2 {
                if abs(dx) < 2 && abs(dz) < 2 { continue }
                for dy in [0, 1] {
                    if (game.world.getBlock(pos.x + dx, pos.y + dy, pos.z + dz) >> 4) == Int(B.bookshelf) { n += 1 }
                }
            }
        }
        bookshelves = min(15, n)
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 14, y: py + 46,
            get: { [weak self] in self?.item },
            set: { [weak self] s in
                self?.item = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 34, y: py + 46,
            get: { [weak self] in self?.lapis },
            set: { [weak self] s in
                self?.lapis = s
                self?.refresh()
            },
            canPlace: { itemDef($0.id).name == "lapis_lazuli" },
            onChange: { [weak self] in self?.refresh() }))
    }
    public func refresh() {
        options = enchantingOptions(item, bookshelves, seed)
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        let cv = ui.cv
        let px = panelX, py = panelY
        let lapisCount = lapis?.count ?? 0
        for i in 0..<3 {
            let opt = i < options.count ? options[i] : nil
            let bx = px + 60, by = py + 14 + Double(i) * 19, bw = 108.0, bh = 18.0
            let affordable = opt != nil && game.player.xpLevel >= opt!.level && lapisCount >= opt!.lapis
            let hover = ui.mouseX >= bx && ui.mouseX < bx + bw && ui.mouseY >= by && ui.mouseY < by + bh
            cv.setFill(opt == nil ? "#3a3a3a" : affordable ? (hover ? "#5a4a8a" : "#4a3a6a") : "#3a3a3a")
            cv.fillRect(bx, by, bw, bh)
            if let opt {
                cv.drawText(String(opt.level), bx + bw - 12, by + 9, 1, affordable ? "#80ff20" : "#407f10")
                if let e = opt.preview {
                    let label = e.id.replacingOccurrences(of: "_", with: " ") + " " + ["I", "II", "III", "IV", "V"][min(4, e.lvl - 1)] + "…"
                    cv.drawText(label, bx + 4, by + 5, 1, affordable ? "#d8c8f8" : "#707070")
                }
                cv.drawText(String(repeating: "•", count: opt.lapis), bx + 4, by + 12, 1, "#3c5ac8")
            }
        }
        cv.drawText("Bookshelves: \(bookshelves)", px + 60, py + 73, 1, "#3f3f3f", shadow: false)
    }
    public override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let px = panelX, py = panelY
        for i in 0..<3 {
            let bx = px + 60, by = py + 14 + Double(i) * 19
            if mx >= bx && mx < bx + 108 && my >= by && my < by + 18 {
                if i < options.count, let item = self.item {
                    let opt = options[i]
                    if game.player.xpLevel >= opt.level && (lapis?.count ?? 0) >= opt.lapis {
                        self.item = applyEnchanting(item, opt)
                        lapis!.count -= opt.lapis
                        if lapis!.count <= 0 { lapis = nil }
                        game.player.takeLevels(opt.lapis)
                        seed = Int.random(in: 0..<1_000_000_000)
                        refresh()
                        game.playUISound("block.enchantment_table.use")
                        game.advance("enchant_item")
                    }
                }
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let item { _ = game.player.give(item) }
        if let lapis { _ = game.player.give(lapis) }
    }
}

// =============================================================================
// Anvil
// =============================================================================
public final class AnvilScreen: ContainerScreen {
    public var left: ItemStack?
    public var right: ItemStack?
    public var result: ItemStack?
    public var cost = 0
    public let nameField = TextField(0, 0, 96, 14)
    private var pos: (x: Int, y: Int, z: Int, damage: Int)

    public init(_ pos: (x: Int, y: Int, z: Int, damage: Int)) {
        self.pos = pos
        super.init()
        title = "Repair & Name"
        sheet = "anvil"
    }
    public override func initScreen(_ ui: UIManager, _ game: GameCore) {
        super.initScreen(ui, game)
        nameField.x = panelX + 60
        nameField.y = panelY + 22
        fields.append(nameField)
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 26, y: py + 46,
            get: { [weak self] in self?.left },
            set: { [weak self] s in
                self?.left = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 75, y: py + 46,
            get: { [weak self] in self?.right },
            set: { [weak self] s in
                self?.right = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 133, y: py + 46,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game, weak ui] _ in
                guard let self, let game, let ui else { return }
                game.player.takeLevels(self.cost)
                self.left = nil
                if let right = self.right {
                    let units = self.result?.data.repairUnits
                    if let units, right.count > units {
                        right.count -= units
                    } else {
                        self.right = nil
                    }
                }
                self.result?.data.repairUnits = nil
                self.result = nil
                self.cost = 0
                // anvil degrade
                if Double.random(in: 0..<1) < 0.12 {
                    let (x, y, z, damage) = self.pos
                    let c = game.world.getBlock(x, y, z)
                    if damage >= 2 {
                        game.world.setBlock(x, y, z, 0)
                        game.world.hooks.playSound("block.anvil.destroy", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                        ui.closeTop(game)
                    } else {
                        game.world.setBlock(x, y, z, Int(cell(damage == 0 ? B.chipped_anvil : B.damaged_anvil, c & 15)))
                        self.pos.damage += 1
                    }
                }
                game.world.hooks.playSound("block.anvil.use", Double(self.pos.x) + 0.5, Double(self.pos.y) + 0.5, Double(self.pos.z) + 0.5, 1, 1)
            }))
    }
    public func refresh() {
        let r = anvilCombine(left, right, nameField.text.isEmpty ? nil : nameField.text)
        result = r?.out
        cost = r?.cost ?? 0
    }
    public override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        let r = super.onChar(ui, game, ch)
        if r { refresh() }
        return r
    }
    public override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let r = super.onKey(ui, game, key)
        if r { refresh() }
        return r
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        if cost > 0 {
            let ok = game.player.xpLevel >= cost && cost < 40
            ui.cv.drawText(cost >= 40 ? "Too Expensive!" : "Enchantment Cost: \(cost)",
                           panelX + 8, panelY + 71, 1, ok ? "#80ff20" : "#ff5050")
        }
        if !textured {
            ui.cv.drawText("+", panelX + 56, panelY + 50, 1, "#3f3f3f", shadow: false)
        }
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if textured {
            // vanilla text-field art strip below the GUI in anvil.png
            ui.blitSheet("anvil", 0, 166, 110, 16, panelX + 59, panelY + 20)
        }
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let left { _ = game.player.give(left) }
        if let right { _ = game.player.give(right) }
    }
}

// =============================================================================
// Grindstone
// =============================================================================
public final class GrindstoneScreen: ContainerScreen {
    public var top: ItemStack?
    public var bottom: ItemStack?
    public var result: ItemStack?
    public var xp = 0

    public override init() {
        super.init()
        title = "Repair & Disenchant"
        sheet = "grindstone"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 18,
            get: { [weak self] in self?.top },
            set: { [weak self] s in
                self?.top = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 39,
            get: { [weak self] in self?.bottom },
            set: { [weak self] s in
                self?.bottom = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 128, y: py + 33,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self, let game else { return }
                self.top = nil
                self.bottom = nil
                self.result = nil
                if self.xp > 0 {
                    spawnXP(game.world, game.player.x, game.player.y, game.player.z, self.xp)
                }
                self.xp = 0
                game.playUISound("block.grindstone.use")
            }))
    }
    public func refresh() {
        let r = grindstoneResult(top, bottom)
        result = r?.out
        xp = r?.xp ?? 0
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let top { _ = game.player.give(top) }
        if let bottom { _ = game.player.give(bottom) }
    }
}

// =============================================================================
// Stonecutter
// =============================================================================
public final class StonecutterScreen: ContainerScreen {
    public var input: ItemStack?
    public var selected = -1
    public var options: [(output: String, count: Int)] = []

    public override init() {
        super.init()
        title = "Stonecutter"
        sheet = "stonecutter"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 19, y: py + 32,
            get: { [weak self] in self?.input },
            set: { [weak self] s in
                self?.input = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 142, y: py + 32,
            get: { [weak self] in
                guard let self, self.selected >= 0, self.input != nil, self.selected < self.options.count else { return nil }
                let o = self.options[self.selected]
                return ItemStack(iid(o.output), o.count)
            },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self else { return }
                if let input = self.input {
                    let sel = self.selected
                    input.count -= 1
                    if input.count <= 0 { self.input = nil }
                    self.refresh()
                    // keep the recipe selected while input remains (refresh
                    // clears it), so repeated/shift takes keep cutting
                    if self.input != nil && sel >= 0 && sel < self.options.count {
                        self.selected = sel
                    }
                }
                game?.playUISound("ui.stonecutter.take_result")
            }))
    }
    public func refresh() {
        options = []
        selected = -1
        guard let input else { return }
        let name = itemDef(input.id).name
        for r in stonecuttingRecipes where r.input == name {
            options.append((r.output, r.count))
        }
    }
    private var gridX: Double { panelX + (textured ? 52 : 48) }
    private var gridY: Double { panelY + (textured ? 15 : 14) }
    private var cellW: Double { textured ? 16 : 18 }

    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        let cv = ui.cv
        for i in 0..<min(12, options.count) {
            let ox = gridX + Double(i % 4) * cellW, oy = gridY + Double(i / 4) * 18
            if textured {
                if i == selected {
                    cv.setFill("rgba(138,138,255,0.55)")
                    cv.fillRect(ox, oy, cellW, 18)
                }
            } else {
                cv.setFill(i == selected ? "#8a8aff" : "#5a5a5a")
                cv.fillRect(ox, oy, cellW, 18)
            }
            cv.drawItemIcon(iid(options[i].output), nil, ox + (cellW - 16) / 2, oy + 1, 16, 16)
        }
    }
    public override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let px = gridX, py = gridY
        if mx >= px && mx < px + cellW * 4 && my >= py && my < py + 54 {
            let i = Int((mx - px) / cellW) + Int((my - py) / 18) * 4
            if i >= 0 && i < options.count {
                selected = i
                game.playUISound("ui.stonecutter.select_recipe")
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let input { _ = game.player.give(input) }
    }
}

// =============================================================================
// Smithing table
// =============================================================================
public final class SmithingScreen: ContainerScreen {
    public var template: ItemStack?
    public var base: ItemStack?
    public var addition: ItemStack?
    public var result: ItemStack?

    public override init() {
        super.init()
        title = "Upgrade Gear"
        titleX = 44
        sheet = "smithing"
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        func mk(_ x: Double, _ getF: @escaping () -> ItemStack?, _ setF: @escaping (ItemStack?) -> Void) -> SlotDef {
            SlotDef(
                x: px + x, y: py + 47,
                get: getF,
                set: { [weak self] s in
                    setF(s)
                    self?.refresh()
                },
                onChange: { [weak self] in self?.refresh() })
        }
        containerSlots.append(mk(7, { [weak self] in self?.template }, { [weak self] in self?.template = $0 }))
        containerSlots.append(mk(25, { [weak self] in self?.base }, { [weak self] in self?.base = $0 }))
        containerSlots.append(mk(43, { [weak self] in self?.addition }, { [weak self] in self?.addition = $0 }))
        containerSlots.append(SlotDef(
            x: px + 97, y: py + 47,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self else { return }
                self.consumeOne(&self.template)
                self.consumeOne(&self.base)
                self.consumeOne(&self.addition)
                self.result = nil
                self.refresh()
                game?.playUISound("block.smithing_table.use")
            }))
    }
    private func consumeOne(_ s: inout ItemStack?) {
        if let stack = s {
            stack.count -= 1
            if stack.count <= 0 { s = nil }
        }
    }
    public func refresh() {
        result = matchSmithing(template, base, addition)
    }
    public override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if !textured {
            ui.cv.drawText("▶", panelX + 74, panelY + 48, 1, "#3f3f3f", shadow: false)
        }
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        for s in [template, base, addition] {
            if let s { _ = game.player.give(s) }
        }
        template = nil
        base = nil
        addition = nil
    }
}

// =============================================================================
// Beacon
// =============================================================================
public final class BeaconScreen: Screen {
    public var payment: ItemStack?
    public var pendingPrimary: String?
    public var panelX = 0.0
    public var panelY = 0.0
    private let be: BlockEntityData

    public init(_ be: BlockEntityData) {
        self.be = be
        super.init()
    }
    public override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - 200) / 2).rounded(.down)
        panelY = ((ui.height - 120) / 2).rounded(.down)
        slots.append(SlotDef(
            x: panelX + 160, y: panelY + 90,
            get: { [weak self] in self?.payment },
            set: { [weak self] in self?.payment = $0 },
            canPlace: { ["iron_ingot", "gold_ingot", "diamond", "emerald", "netherite_ingot"].contains(itemDef($0.id).name) }))
        pendingPrimary = be.primary
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        ui.drawPanel(panelX, panelY, 200, 120)
        let cv = ui.cv
        cv.drawText("Beacon (Pyramid level \(be.levels ?? 0))", panelX + 8, panelY + 6, 1, "#3f3f3f", shadow: false)
        let powers: [(String, String, Int)] = [
            ("speed", "Speed", 1), ("haste", "Haste", 1),
            ("resistance", "Resistance", 2), ("jump_boost", "Jump Boost", 2),
            ("strength", "Strength", 3),
        ]
        for (i, p) in powers.enumerated() {
            let bx = panelX + 10 + Double(i % 2) * 92
            let by = panelY + 20 + Double(i / 2) * 22
            let unlocked = (be.levels ?? 0) >= p.2
            let sel = pendingPrimary == p.0
            cv.setFill(!unlocked ? "#3a3a3a" : sel ? "#6a8aff" : "#5a5a5a")
            cv.fillRect(bx, by, 88, 18)
            cv.drawText(p.1, bx + 5, by + 5, 1, unlocked ? "#ffffff" : "#808080")
        }
        cv.drawText("Pay:", panelX + 132, panelY + 95, 1, "#3f3f3f", shadow: false)
        ui.drawSlots(self)
        let can = pendingPrimary != nil && payment != nil && (be.levels ?? 0) > 0
        cv.setFill(can ? "#4a8a4a" : "#3a3a3a")
        cv.fillRect(panelX + 10, panelY + 92, 60, 16)
        cv.drawTextCentered("Confirm", panelX + 40, panelY + 96, 1, can ? "#ffffff" : "#808080")
    }
    public override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let powers = ["speed", "haste", "resistance", "jump_boost", "strength"]
        let minLvls = [1, 1, 2, 2, 3]
        for i in 0..<powers.count {
            let bx = panelX + 10 + Double(i % 2) * 92
            let by = panelY + 20 + Double(i / 2) * 22
            if mx >= bx && mx < bx + 88 && my >= by && my < by + 18 && (be.levels ?? 0) >= minLvls[i] {
                pendingPrimary = powers[i]
                return true
            }
        }
        if mx >= panelX + 10 && mx < panelX + 70 && my >= panelY + 92 && my < panelY + 108 {
            if let primary = pendingPrimary, let pay = payment, (be.levels ?? 0) > 0 {
                be.primary = primary
                be.secondary = (be.levels ?? 0) >= 4 ? primary : nil
                pay.count -= 1
                if pay.count <= 0 { payment = nil }
                game.playUISound("block.beacon.power_select")
                ui.closeTop(game)
            }
            return true
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let payment { _ = game.player.give(payment) }
    }
}

// =============================================================================
// Villager trading
// =============================================================================
public final class TradingScreen: ContainerScreen {
    public var selected = 0
    public var buyA: ItemStack?
    public var buyB: ItemStack?
    private let villager: Mob

    public init(_ villager: Mob) {
        self.villager = villager
        super.init()
        panelW = 250
        title = "Trading"
    }
    public var offers: [TradeOffer] {
        (villager as? Villager)?.offers ?? (villager as? WanderingTrader)?.offers ?? []
    }
    public override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX + 80, py = panelY
        containerSlots.append(SlotDef(
            x: px + 24, y: py + 40,
            get: { [weak self] in self?.buyA },
            set: { [weak self] in self?.buyA = $0 }))
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 40,
            get: { [weak self] in self?.buyB },
            set: { [weak self] in self?.buyB = $0 }))
        containerSlots.append(SlotDef(
            x: px + 100, y: py + 40,
            get: { [weak self] in self?.tradeResult() },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                if let game { self?.executeTrade(game) }
            }))
        playerSlots = playerInvSlots(game.player, panelX + 80, panelY + panelH - 83)
        slots = containerSlots + playerSlots
    }
    public func tradeResult() -> ItemStack? {
        guard selected < offers.count else { return nil }
        let o = offers[selected]
        if o.uses >= o.maxUses { return nil }
        if !matches(buyA, o.buyA) { return nil }
        if let b = o.buyB, !matches(buyB, b) { return nil }
        return copyStack(o.sell)
    }
    private func matches(_ have: ItemStack?, _ want: ItemStack) -> Bool {
        guard let have else { return false }
        return have.id == want.id && have.count >= want.count
    }
    private func executeTrade(_ game: GameCore) {
        guard selected < offers.count else { return }
        let o = offers[selected]
        buyA!.count -= o.buyA.count
        if buyA!.count <= 0 { buyA = nil }
        if let b = o.buyB, let mine = buyB {
            mine.count -= b.count
            if mine.count <= 0 { buyB = nil }
        }
        if let v = villager as? Villager {
            v.offers[selected].uses += 1
            v.addTradeXP(o.xp)
        } else if let w = villager as? WanderingTrader {
            w.offers[selected].uses += 1
        }
        game.playUISound("entity.villager.yes")
        game.advance("trade_villager")
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        ui.drawPanel(panelX, panelY, panelW, panelH)
        let cv = ui.cv
        let prof = (villager as? Villager)?.profession ?? "wandering trader"
        let lvl = (villager as? Villager).map { String($0.tradeLevel) } ?? "-"
        cv.drawText("\(prof.prefix(1).uppercased())\(prof.dropFirst()) (lvl \(lvl))", panelX + 8, panelY + 6, 1, "#3f3f3f", shadow: false)
        for (i, o) in offers.enumerated() where i < 7 {
            let oy = panelY + 18 + Double(i) * 20
            let hover = ui.mouseX >= panelX + 5 && ui.mouseX < panelX + 75 && ui.mouseY >= oy && ui.mouseY < oy + 20
            cv.setFill(i == selected ? "#6a8aff" : hover ? "#7a7a7a" : "#5a5a5a")
            cv.fillRect(panelX + 5, oy, 72, 20)
            cv.drawItemIcon(o.buyA.id, nil, panelX + 7, oy + 2, 16, 16)
            cv.drawText(String(o.buyA.count), panelX + 18, oy + 10, 1)
            cv.drawText("→", panelX + 32, oy + 6, 1, "#e8e8e8")
            cv.drawItemIcon(o.sell.id, o.sell.data, panelX + 46, oy + 2, 16, 16)
            if o.sell.count > 1 { cv.drawText(String(o.sell.count), panelX + 58, oy + 10, 1) }
            if o.uses >= o.maxUses {
                cv.setFill("rgba(180,0,0,0.4)")
                cv.fillRect(panelX + 5, oy, 72, 20)
            }
        }
        cv.drawText("Trade", panelX + 104, panelY + 28, 1, "#3f3f3f", shadow: false)
        ui.drawSlots(self)
    }
    public override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        for i in 0..<min(offers.count, 7) {
            let oy = panelY + 18 + Double(i) * 20
            if mx >= panelX + 5 && mx < panelX + 77 && my >= oy && my < oy + 20 {
                selected = i
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let buyA { _ = game.player.give(buyA) }
        if let buyB { _ = game.player.give(buyB) }
    }
}

// =============================================================================
// Creative inventory
// =============================================================================
private let CREATIVE_TABS: [(String, String)] = [
    ("building", "Building"), ("colored", "Colored"), ("natural", "Natural"),
    ("functional", "Functional"), ("redstone", "Redstone"), ("tools", "Tools"),
    ("combat", "Combat"), ("food", "Food"), ("ingredients", "Ingredients"), ("spawn_eggs", "Eggs"),
]

public final class CreativeScreen: ContainerScreen {
    public var tab = 0
    public var scroll = 0
    public let search = TextField(0, 0, 80, 12)
    public var filtered: [Int] = []

    public override init() {
        super.init()
        panelW = 195
        panelH = 186
        title = ""
    }
    public override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - panelW) / 2).rounded(.down)
        panelY = ((ui.height - panelH) / 2).rounded(.down)
        search.x = panelX + 100
        search.y = panelY + 5
        fields.append(search)
        playerSlots = []
        let p = game.player!
        for col in 0..<9 {
            let idx = col
            playerSlots.append(SlotDef(
                x: panelX + 8 + Double(col) * 18, y: panelY + 160,
                get: { p.inventory[idx] },
                set: { p.inventory[idx] = $0 }))
        }
        refresh()
        slots = playerSlots
    }
    public func refresh() {
        let cat = CREATIVE_TABS[tab].0
        let q = search.text.lowercased()
        filtered = []
        for i in 0..<itemDefs.count {
            let d = itemDefs[i]
            if !q.isEmpty {
                if d.name.contains(q) || d.displayName.lowercased().contains(q) { filtered.append(i) }
            } else if d.category == cat {
                filtered.append(i)
            }
        }
        scroll = min(scroll, max(0, (filtered.count + 8) / 9 - 6))
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        let cv = ui.cv
        for i in 0..<CREATIVE_TABS.count {
            let tx = panelX + Double(i % 5) * 39
            let ty = i < 5 ? panelY - 14 : panelY + panelH
            cv.setFill(i == tab ? "#c6c6c6" : "#8a8a8a")
            cv.fillRect(tx, ty, 38, 14)
            cv.drawText(String(CREATIVE_TABS[i].1.prefix(7)), tx + 2, ty + 3, 1, i == tab ? "#3f3f3f" : "#e8e8e8", shadow: false)
        }
        ui.drawPanel(panelX, panelY, panelW, panelH)
        for row in 0..<6 {
            for col in 0..<9 {
                let gx = panelX + 8 + Double(col) * 18
                let gy = panelY + 22 + Double(row) * 18
                ui.drawSlotBg(gx, gy)
                let idx = (scroll + row) * 9 + col
                if idx < filtered.count {
                    let stack = ItemStack(filtered[idx], 1)
                    ui.drawItemStack(stack, gx, gy)
                    if ui.mouseX >= gx && ui.mouseX < gx + 18 && ui.mouseY >= gy && ui.mouseY < gy + 18 {
                        cv.setFill("rgba(255,255,255,0.45)")
                        cv.fillRect(gx + 1, gy + 1, 16, 16)
                        ui.tooltipLines = ui.itemTooltip(stack)
                    }
                }
            }
        }
        let maxScroll = max(0, (filtered.count + 8) / 9 - 6)
        cv.setFill("#1c1c1c")
        cv.fillRect(panelX + panelW - 16, panelY + 22, 10, 108)
        let sf = maxScroll == 0 ? 0.0 : Double(scroll) / Double(maxScroll)
        cv.setFill("#c8c8c8")
        cv.fillRect(panelX + panelW - 16, panelY + 22 + (sf * 93).rounded(), 10, 15)
        ui.drawSlots(self)
        ui.drawButtons(self)
        cv.drawText("Destroy item: drop on grid", panelX + 4, panelY + 6, 1, "#3f3f3f", shadow: false)
    }
    public override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        for i in 0..<CREATIVE_TABS.count {
            let tx = panelX + Double(i % 5) * 39
            let ty = i < 5 ? panelY - 14 : panelY + panelH
            if mx >= tx && mx < tx + 38 && my >= ty && my < ty + 14 {
                tab = i
                search.text = ""
                refresh()
                return true
            }
        }
        if mx >= panelX + 8 && mx < panelX + 8 + 162 && my >= panelY + 22 && my < panelY + 22 + 108 {
            let col = Int((mx - panelX - 8) / 18)
            let row = Int((my - panelY - 22) / 18)
            let idx = (scroll + row) * 9 + col
            if ui.cursorStack != nil {
                ui.cursorStack = nil // destroy
            } else if idx < filtered.count {
                let id = filtered[idx]
                ui.cursorStack = ItemStack(id, btn == 2 ? 1 : maxStackOf(ItemStack(id, 1)))
            }
            return true
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    public override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        let maxScroll = max(0, (filtered.count + 8) / 9 - 6)
        scroll = max(0, min(maxScroll, scroll + (dy > 0 ? 1 : -1)))
        return true
    }
    public override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        let r = super.onChar(ui, game, ch)
        if r { refresh() }
        return r
    }
    public override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let r = super.onKey(ui, game, key)
        if r { refresh() }
        return r
    }
}

// =============================================================================
// Sign editing
// =============================================================================
public final class SignScreen: Screen {
    public var lines = ["", "", "", ""]
    public var lineIdx = 0
    private let be: BlockEntityData?
    private let pos: (x: Int, y: Int, z: Int)

    public init(_ be: BlockEntityData?, _ pos: (x: Int, y: Int, z: Int)) {
        self.be = be
        self.pos = pos
        super.init()
        if let l = be?.lines { lines = l }
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.5)
        let w = 140.0, h = 80.0
        let px = ((ui.width - w) / 2).rounded(.down), py = ((ui.height - h) / 2).rounded(.down)
        let cv = ui.cv
        cv.setFill("#9a7444")
        cv.fillRect(px, py, w, h)
        cv.setFill("#85643a")
        cv.fillRect(px + 2, py + 2, w - 4, h - 4)
        for i in 0..<4 {
            let blink = i == lineIdx && Int(uiNow() * 1000 / 400) % 2 == 0 ? "_" : ""
            cv.drawTextCentered(lines[i] + blink, px + w / 2, py + 12 + Double(i) * 15, 1, "#1c1208", shadow: false)
        }
        cv.drawTextCentered("Press Enter / Esc to finish", px + w / 2, py + h + 8, 1)
    }
    public override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        if textWidth(lines[lineIdx] + ch) < 90 {
            lines[lineIdx] += ch
        }
        return true
    }
    public override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if key == "Backspace" {
            if !lines[lineIdx].isEmpty { lines[lineIdx].removeLast() }
            return true
        }
        if key == "Enter" || key == "ArrowDown" {
            lineIdx = (lineIdx + 1) % 4
            if key == "Enter" && lineIdx == 0 { ui.closeTop(game) }
            return true
        }
        if key == "ArrowUp" {
            lineIdx = (lineIdx + 3) % 4
            return true
        }
        return false
    }
    public override func onClose(_ ui: UIManager, _ game: GameCore) {
        var sign = be
        if sign == nil {
            sign = makeSignBE(pos.x, pos.y, pos.z)
            game.world.setBlockEntity(sign!)
        }
        sign!.lines = lines
    }
}

// =============================================================================
// Death screen
// =============================================================================
public final class DeathScreen: Screen {
    private let causeText: String

    public init(_ causeText: String) {
        self.causeText = causeText
        super.init()
        closeOnEsc = false
    }
    public override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        buttons.append(Button(cx - 100, (ui.height / 2).rounded(.down), 200, 20, "Respawn", { [weak ui, weak game] in
            guard let ui, let game else { return }
            game.respawnPlayer()
            ui.closeAll(game)
        }))
        buttons.append(Button(cx - 100, (ui.height / 2).rounded(.down) + 24, 200, 20, "Title Screen", { [weak game] in
            game?.exitToTitle()
        }))
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.cv.setFill("rgba(120,0,0,0.45)")
        ui.cv.fillRect(0, 0, ui.width, ui.height)
        ui.cv.drawTextCentered("You Died!", ui.width / 2, ui.height / 2 - 50, 3)
        ui.cv.drawTextCentered(causeText, ui.width / 2, ui.height / 2 - 24, 1)
        ui.cv.drawTextCentered("Score: §e\(game.player.xpLevel * 7)", ui.width / 2, ui.height / 2 - 12, 1)
        ui.drawButtons(self)
    }
}

// =============================================================================
// Chat / command screen + chat log
// =============================================================================
public struct ChatMessage {
    var text: String
    var time: Double
}
public var chatLog: [ChatMessage] = []
public func pushChat(_ text: String) {
    chatLog.append(ChatMessage(text: text, time: uiNow() * 1000))
    if chatLog.count > 100 { chatLog.removeFirst() }
}

public final class ChatScreen: Screen {
    public var input = ""
    public var historyIdx = -1
    public static var history: [String] = []
    private let runCommandFn: (String) -> Void

    public init(_ runCommand: @escaping (String) -> Void, _ prefill: String = "") {
        runCommandFn = runCommand
        input = prefill
        super.init()
    }
    public override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let cv = ui.cv
        let maxN = min(chatLog.count, 18)
        for i in 0..<maxN {
            let msg = chatLog[chatLog.count - 1 - i]
            let y = ui.height - 36 - Double(i) * 10
            cv.setFill("rgba(0,0,0,0.5)")
            cv.fillRect(2, y, min(ui.width * 0.6, Double(textWidth(msg.text)) + 4), 10)
            cv.drawText(msg.text, 4, y + 1, 1)
        }
        cv.setFill("rgba(0,0,0,0.6)")
        cv.fillRect(2, ui.height - 14, ui.width - 4, 12)
        let blink = Int(uiNow() * 1000 / 400) % 2 == 0 ? "_" : ""
        cv.drawText(input + blink, 4, ui.height - 12, 1)
    }
    public override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        input += ch
        return true
    }
    public override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if key == "Backspace" {
            if !input.isEmpty { input.removeLast() }
            return true
        }
        if key == "Enter" {
            if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                ChatScreen.history.append(input)
                runCommandFn(input)
            }
            ui.closeTop(game)
            return true
        }
        if key == "ArrowUp" {
            if !ChatScreen.history.isEmpty {
                historyIdx = historyIdx < 0 ? ChatScreen.history.count - 1 : max(0, historyIdx - 1)
                input = ChatScreen.history[historyIdx]
            }
            return true
        }
        if key == "ArrowDown" {
            if historyIdx >= 0 {
                historyIdx = min(ChatScreen.history.count - 1, historyIdx + 1)
                input = ChatScreen.history[historyIdx]
            }
            return true
        }
        return false
    }
}

/// draws recent chat while playing (no screen open)
public func drawChatOverlay(_ ui: UIManager) {
    let now = uiNow() * 1000
    let cv = ui.cv
    var shown = 0
    var i = chatLog.count - 1
    while i >= 0 && shown < 8 {
        let msg = chatLog[i]
        let age = now - msg.time
        if age > 8000 { break }
        let alpha = age > 6000 ? 1 - (age - 6000) / 2000 : 1
        let y = ui.height - 44 - Double(shown) * 10
        cv.globalAlpha = Float(alpha)
        cv.setFill("rgba(0,0,0,0.45)")
        cv.fillRect(2, y, min(ui.width * 0.6, Double(textWidth(msg.text)) + 4), 10)
        cv.drawText(msg.text, 4, y + 1, 1)
        cv.globalAlpha = 1
        shown += 1
        i -= 1
    }
}
