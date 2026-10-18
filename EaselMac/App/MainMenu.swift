import AppKit
import Paintbrush

/// The menu bar. Items send their actions up the responder chain: the
/// editor answers for the picture, the window controller for the document,
/// and AppKit for the rest.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        for submenu in [appMenu(), fileMenu(), editMenu(), imageMenu(), layerMenu(), selectMenu(), filterMenu(), viewMenu(), toolsMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item(String(localized: "Menu.About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Menu.Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: services.title)
        NSApplication.shared.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Menu.HideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Menu.ShowAll"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.File"))
        menu.addItem(item(String(localized: "Launch.NewImage"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Menu.Open"), #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenuItem(title: String(localized: "Menu.OpenRecent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: recent.title)
        recentMenu.addItem(item(String(localized: "Menu.ClearRecent"), #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Menu.Save"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(String(localized: "Menu.Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Menu.Rename"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Menu.MoveTo"), #selector(NSDocument.move(_:))))
        menu.addItem(item(String(localized: "Menu.RevertToSaved"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.ImportImage"), #selector(EditorViewController.importImage(_:)), "i", [.command, .option]))
        let export = NSMenuItem(title: String(localized: "Menu.Export"), action: nil, keyEquivalent: "")
        export.submenu = exportMenu()
        menu.addItem(export)
        menu.addItem(item(String(localized: "TitleMenu.ConvertToEasel"), #selector(EditorWindowController.convertToEasel(_:))))
        menu.addItem(item(String(localized: "Toolbar.UnsupportedFeatures"), #selector(EditorViewController.showUnsupportedFeatures(_:))))
        return menu
    }

    /// Each format to export as, and the presets.
    static func exportMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Export"))
        for (index, format) in CompositionExport.Format.allCases.enumerated() {
            let entry = item(format.labelString + "…", #selector(EditorWindowController.exportAs(_:)))
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "ExportPreset.Menu") + "…", #selector(EditorWindowController.exportWithPresets(_:)), "e", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Edit"))
        menu.addItem(item(String(localized: "Toolbar.Undo"), #selector(EditorViewController.undo(_:)), "z"))
        menu.addItem(item(String(localized: "Toolbar.Redo"), #selector(EditorViewController.redo(_:)), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Edit.Cut"), #selector(EditorViewController.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Edit.Copy"), #selector(EditorViewController.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Edit.Paste"), #selector(EditorViewController.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Select.Clear"), #selector(EditorViewController.delete(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Select.All"), #selector(EditorViewController.selectAll(_:)), "a"))
        return menu
    }

    /// Making a selection, changing it, and what can be done with it.
    private static func selectMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Select"))
        menu.addItem(item(String(localized: "Select.All"), #selector(EditorViewController.selectAll(_:))))
        menu.addItem(item(String(localized: "Select.Deselect"), #selector(EditorViewController.deselect(_:)), "d"))
        menu.addItem(item(String(localized: "Select.Invert"), #selector(EditorViewController.invertSelection(_:)), "i", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Select.Subject"), #selector(EditorViewController.selectSubject(_:))))
        menu.addItem(item(String(localized: "Select.ColorRange"), #selector(EditorViewController.selectColorRange(_:))))
        menu.addItem(.separator())
        let modify = NSMenuItem(title: String(localized: "Select.Modify"), action: nil, keyEquivalent: "")
        let modifyMenu = NSMenu(title: modify.title)
        for (index, modification) in SelectionModification.allCases.enumerated() {
            let entry = item(
                String(localized: String.LocalizationValue("Select.\(modification.rawValue.capitalized)")) + "…",
                #selector(EditorViewController.modifySelection(_:))
            )
            entry.tag = index
            modifyMenu.addItem(entry)
        }
        modify.submenu = modifyMenu
        menu.addItem(modify)
        menu.addItem(item(String(localized: "Select.RefineEdge") + "…", #selector(EditorViewController.refineSelectionEdge(_:))))
        menu.addItem(item(String(localized: "Select.Stroke") + "…", #selector(EditorViewController.strokeSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Select.CopyToLayer"), #selector(EditorViewController.copySelectionToLayer(_:))))
        menu.addItem(item(String(localized: "Select.CutToLayer"), #selector(EditorViewController.cutSelectionToLayer(_:))))
        menu.addItem(item(String(localized: "Select.Fill"), #selector(EditorViewController.fillSelection(_:))))
        menu.addItem(item(String(localized: "Select.FillFromSurroundings"), #selector(EditorViewController.fillSelectionFromSurroundings(_:))))
        menu.addItem(item(String(localized: "Pattern.Define"), #selector(EditorViewController.definePattern(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Select.CropToSelection"), #selector(EditorViewController.cropToSelection(_:))))
        return menu
    }

    /// Every filter to add to the active layer, by kind, and the panels
    /// that change its colours as a whole.
    private static func filterMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Filter"))
        for (index, category) in LayerFilter.Kind.categories.enumerated() {
            let target: NSMenu
            if let title = category.titleKey {
                let submenuItem = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: nil, keyEquivalent: "")
                target = NSMenu(title: submenuItem.title)
                submenuItem.submenu = target
                if index > 0, LayerFilter.Kind.categories[index - 1].titleKey == nil { menu.addItem(.separator()) }
                menu.addItem(submenuItem)
            } else {
                if index > 0 { menu.addItem(.separator()) }
                target = menu
            }
            for kind in category.kinds {
                let entry = item(kind.label, #selector(EditorViewController.addFilter(_:)))
                entry.tag = LayerFilter.Kind.allCases.firstIndex(of: kind) ?? 0
                entry.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
                target.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Panel.Adjustments.Title") + "…", #selector(EditorViewController.showAdjustments(_:))))
        menu.addItem(item(String(localized: "Panel.Looks.Title") + "…", #selector(EditorViewController.showAdjustments(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "LayerFilters.ApplyAll"), #selector(EditorViewController.applyFilters(_:))))
        menu.addItem(item(String(localized: "LayerFilters.RemoveAll"), #selector(EditorViewController.removeFilters(_:))))
        return menu
    }

    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Image"))
        menu.addItem(item(String(localized: "Canvas.ImageSize"), #selector(EditorViewController.showImageSize(_:)), "i", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Canvas.RotateLeft"), #selector(EditorViewController.rotateCanvasLeft(_:))))
        menu.addItem(item(String(localized: "Canvas.RotateRight"), #selector(EditorViewController.rotateCanvasRight(_:))))
        menu.addItem(item(String(localized: "Canvas.FlipHorizontal"), #selector(EditorViewController.flipCanvasHorizontally(_:))))
        menu.addItem(item(String(localized: "Canvas.FlipVertical"), #selector(EditorViewController.flipCanvasVertically(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Layers.Flatten"), #selector(EditorViewController.flattenImage(_:))))
        return menu
    }

    private static func layerMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Layer"))
        menu.addItem(item(String(localized: "Layers.NewLayer"), #selector(EditorViewController.newLayer(_:)), "n", [.command, .shift]))
        menu.addItem(item(String(localized: "Layers.Duplicate"), #selector(EditorViewController.duplicateLayer(_:)), "j"))
        menu.addItem(item(String(localized: "Layers.Delete"), #selector(EditorViewController.deleteLayer(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Layers.MergeDown"), #selector(EditorViewController.mergeLayerDown(_:)), "e"))
        menu.addItem(item(String(localized: "Groups.Group"), #selector(EditorViewController.groupLayer(_:)), "g"))
        menu.addItem(item(String(localized: "Layers.Rasterize"), #selector(EditorViewController.rasterizeLayer(_:))))
        menu.addItem(.separator())
        let styles = NSMenuItem(title: String(localized: "LayerEffects.Add"), action: nil, keyEquivalent: "")
        let stylesMenu = NSMenu(title: styles.title)
        for (index, kind) in LayerEffect.Kind.allCases.enumerated() {
            let entry = item(kind.label, #selector(EditorViewController.addEffect(_:)))
            entry.tag = index
            entry.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            stylesMenu.addItem(entry)
        }
        styles.submenu = stylesMenu
        menu.addItem(styles)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "SmartObject.Convert"), #selector(EditorViewController.convertToSmartObject(_:))))
        menu.addItem(item(String(localized: "SmartObject.Edit"), #selector(EditorViewController.editSmartObjectContents(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Mask.Add"), #selector(EditorViewController.addMask(_:))))
        menu.addItem(item(String(localized: "Mask.Apply"), #selector(EditorViewController.applyMask(_:))))
        menu.addItem(item(String(localized: "Mask.Invert"), #selector(EditorViewController.invertMask(_:))))
        menu.addItem(item(String(localized: "Mask.Delete"), #selector(EditorViewController.deleteMask(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Layers.MoveUp"), #selector(EditorViewController.moveLayerUp(_:)), "]"))
        menu.addItem(item(String(localized: "Layers.MoveDown"), #selector(EditorViewController.moveLayerDown(_:)), "["))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Layers.Hide"), #selector(EditorViewController.toggleLayerVisibility(_:)), ",", [.command]))
        menu.addItem(item(String(localized: "Layers.Lock"), #selector(EditorViewController.toggleLayerLock(_:)), "/", [.command]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.View"))
        menu.addItem(item(String(localized: "Menu.ZoomIn"), #selector(EditorViewController.zoomIn(_:)), "+"))
        menu.addItem(item(String(localized: "Menu.ZoomOut"), #selector(EditorViewController.zoomOut(_:)), "-"))
        menu.addItem(item(String(localized: "Canvas.FitToScreen"), #selector(EditorViewController.zoomToFit(_:)), "0"))
        menu.addItem(item(String(localized: "Canvas.ActualSize"), #selector(EditorViewController.zoomToActualSize(_:)), "1"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Canvas.RotateWithGestures"), #selector(EditorViewController.toggleRotatesWithGestures(_:))))
        menu.addItem(item(String(localized: "Canvas.ShowRulers"), #selector(EditorViewController.toggleRulers(_:)), "r"))
        menu.addItem(item(String(localized: "Canvas.ClearGuides"), #selector(EditorViewController.clearGuides(_:))))
        menu.addItem(.separator())
        for (index, panel) in InspectorViewController.tabbedPanels.enumerated() {
            let entry = item(panel.titleString, #selector(EditorViewController.showPanel(_:)), String(index + 1), [.command, .option])
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Text.ShowFonts"), #selector(EditorViewController.showFonts(_:)), "t"))
        menu.addItem(item(String(localized: "Swatches.ShowColors"), #selector(EditorViewController.showColors(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.ShowTools"), #selector(EditorViewController.toggleTools(_:)), "t", [.command, .option]))
        menu.addItem(item(String(localized: "Toolbar.Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .control, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.EnterFullScreen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// The toolbar's zoom pop-up: steps, fitting, and set sizes.
    static func zoomMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.ZoomGroup"))
        menu.addItem(item(String(localized: "Menu.ZoomIn"), #selector(EditorViewController.zoomIn(_:))))
        menu.addItem(item(String(localized: "Menu.ZoomOut"), #selector(EditorViewController.zoomOut(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Canvas.FitToScreen"), #selector(EditorViewController.zoomToFit(_:))))
        menu.addItem(.separator())
        for percent in [25, 50, 75, 100, 150, 200, 400, 800] {
            let entry = item("\(percent)%", #selector(EditorViewController.zoomToPercent(_:)))
            entry.tag = percent
            menu.addItem(entry)
        }
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Tools"))
        for (groupIndex, tools) in Tool.groups.enumerated() {
            if groupIndex > 0 { menu.addItem(.separator()) }
            for tool in tools {
                let entry = item(String(localized: String.LocalizationValue(tool.labelKey)), #selector(EditorViewController.pickTool(_:)))
                entry.tag = Tool.allCases.firstIndex(of: tool) ?? 0
                entry.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil)
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.SmallerBrush"), #selector(EditorViewController.smallerBrush(_:))))
        menu.addItem(item(String(localized: "Menu.LargerBrush"), #selector(EditorViewController.largerBrush(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Window"))
        menu.addItem(item(String(localized: "Menu.Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Menu.Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Menu.BringAllToFront"), #selector(NSApplication.arrangeInFront(_:))))
        NSApplication.shared.windowsMenu = menu
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu.Help"))
        menu.addItem(item(String(localized: "Toolbar.SourceCode"), #selector(AppDelegate.openSourceCode(_:))))
        NSApplication.shared.helpMenu = menu
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

extension CompositionExport.Format {
    /// The format's name, looked up, for places that take a string.
    var labelString: String {
        switch self {
        case .png: String(localized: "Export.PNG")
        case .jpeg: String(localized: "Export.JPEG")
        case .heic: String(localized: "Export.HEIC")
        case .psd: String(localized: "Export.PSD")
        case .svg: String(localized: "Export.SVG")
        case .pdf: String(localized: "Export.PDF")
        case .easel: String(localized: "Export.Easel")
        }
    }
}
