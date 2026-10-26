import GrentonModel

// Stage 1 of the device pipeline (spec §6.1): pure widget → descriptor
// mapping with the completeness rules of spec §6.3. No Runtime types.
/// Turns an interface into devices, with no network access.
///
/// Use it to list an installation's devices without connecting, for example in a setup screen. ``GrentonSystem`` uses it internally.
public enum DeviceMapper {

    /// Every device of the interface, one per widget, in page order. Widgets of an unknown type are left out.
    public static func descriptors(for interface: MobileInterfaceDTO) -> [DeviceDescriptor] {
        interface.pages.enumerated().flatMap { index, page -> [DeviceDescriptor] in
            let devicePage = DevicePage(index: index, name: page.name)
            // The nearest header above, per page (spec §6.1); a header that
            // did not parse is not in `items`, so it starts no section.
            var section: DeviceSection?
            return page.items.compactMap { item in
                switch item {
                case .header(let header):
                    section = DeviceSection(id: header.id, title: header.label)
                    return nil
                case .widget(let widget):
                    return descriptor(for: widget, page: devicePage, section: section)
                }
            }
        }
    }

    /// The device for one widget on a page, under `section` when the page has a header above it.
    public static func descriptor(for widget: WidgetDTO, page: DevicePage, section: DeviceSection? = nil) -> DeviceDescriptor {
        DeviceDescriptor(
            id: widget.id,
            typeName: widget.typeName,
            kind: kind(of: widget),
            page: page,
            section: section,
            name: name(of: widget),
            entities: entities(for: widget))
    }

    // Groups devices by the CLU object each entity operates (spec §6.6).
    // Objects appear in order of first use; each lists its widgets in
    // device order with the entities that belong to it. Entities without
    // an object (cameras) are not grouped.
    /// Groups devices by what they operate on the CLU.
    ///
    /// Objects come in the order they first appear. Each lists the widgets that show it, in device order. Cameras operate nothing on a CLU and are left out.
    public static func physicalObjects(for devices: [DeviceDescriptor]) -> [PhysicalObject] {
        var order: [ObjectKey] = []
        var widgets: [ObjectKey: [PhysicalObject.Widget]] = [:]
        for device in devices {
            var entityIds: [ObjectKey: [String]] = [:]
            var keysInOrder: [ObjectKey] = []
            for entity in device.entities {
                guard let key = entity.objectKey else { continue }
                if entityIds[key] == nil { keysInOrder.append(key) }
                entityIds[key, default: []].append(entity.id)
            }
            for key in keysInOrder {
                if widgets[key] == nil { order.append(key) }
                widgets[key, default: []].append(PhysicalObject.Widget(
                    deviceId: device.id, widgetType: device.typeName, name: device.name,
                    page: device.page, entityIds: entityIds[key] ?? []))
            }
        }
        return order.map { PhysicalObject(key: $0, widgets: widgets[$0] ?? []) }
    }

    /// Device kind table of spec §6.1.
    private static func kind(of widget: WidgetDTO) -> DeviceKind {
        switch widget {
        case .onOff, .onOffDouble: return .switch
        case .dimmerV2: return .dimmableLight
        case .led: return .hsbLight
        case .contactSensor, .contactSensorDouble: return .contactSensor
        case .valueV2, .valueDouble: return .sensor
        case .multisensor: return .multisensor
        case .slider: return .numberSetting
        case .rollerShutter, .rollerShutterV3: return .cover
        case .scene, .sceneDouble: return .scene
        case .camera: return .camera
        case .thermostatV2: return .thermostat
        case .eventScheduler: return .eventSchedule
        case .tvRemoteControl: return .tvRemote
        }
    }

    /// Device name rule of spec §6.1: the widget label when the widget has
    /// one; otherwise its components' non-empty labels joined with " / "
    /// (LED: the BUTTON_BISTABLE label).
    private static func name(of widget: WidgetDTO) -> String {
        func joined(_ labels: [String]) -> String {
            labels.filter { !$0.isEmpty }.joined(separator: " / ")
        }
        switch widget {
        case .valueV2(let w): return w.label
        case .dimmerV2(let w): return w.label
        case .contactSensor(let w): return w.label
        case .slider(let w): return w.label
        case .multisensor(let w): return w.label
        case .rollerShutterV3(let w): return w.label
        case .thermostatV2(let w): return w.label
        case .eventScheduler(let w): return w.label
        case .tvRemoteControl(let w): return w.label
        case .valueDouble(let w): return joined([w.componentLeft.label, w.componentRight.label])
        case .contactSensorDouble(let w): return joined([w.componentLeft.label, w.componentRight.label])
        case .onOff(let w): return joined(w.components.map(\.label))
        case .onOffDouble(let w): return joined(w.components.map(\.label))
        case .rollerShutter(let w): return joined(w.components.map(\.label))
        case .camera(let w): return joined(w.components.map(\.label))
        case .scene(let w): return joined(w.components.map(\.label))
        case .sceneDouble(let w): return joined(w.components.map(\.label))
        case .led(let w):
            for case .button(let button) in w.components { return button.label }
            return ""
        }
    }

    private static func entities(for widget: WidgetDTO) -> [EntityDescriptor] {
        switch widget {
        case .valueV2(let w):
            return [.sensor(SensorDescriptor(
                id: "\(w.id)_0", name: w.label,
                state: ValueRef(dto: w.object.value),
                kind: .generic, grentonUnit: w.unit,
                valueType: w.valueType, precision: w.precision))]

        case .valueDouble(let w):
            // Suffixes _0/_1 — reference unique_id contract (spec §6.3.5).
            return [
                .sensor(SensorDescriptor(
                    id: "\(w.id)_0", name: w.componentLeft.label,
                    state: ValueRef(dto: w.componentLeft.object.value),
                    kind: .generic, grentonUnit: w.componentLeft.unit,
                    valueType: w.componentLeft.valueType,
                    precision: w.componentLeft.precision)),
                .sensor(SensorDescriptor(
                    id: "\(w.id)_1", name: w.componentRight.label,
                    state: ValueRef(dto: w.componentRight.object.value),
                    kind: .generic, grentonUnit: w.componentRight.unit,
                    valueType: w.componentRight.valueType,
                    precision: w.componentRight.precision)),
            ]

        case .onOff(let w):
            return w.components.compactMap { component in
                toggle(widgetId: w.id, label: component.label, rowId: component.rowId,
                       state: component.state, actions: component.actions,
                       onIndication: component.onIndication,
                       offIndication: component.offIndication)
            }

        case .onOffDouble(let w):
            return w.components.compactMap { component in
                toggle(widgetId: w.id, label: component.label, rowId: component.rowId,
                       state: component.state, actions: component.actions,
                       onIndication: component.onIndication,
                       offIndication: component.offIndication)
            }

        case .dimmerV2(let w):
            guard let onAction = try? ActionRef(dto: w.object.onAction),
                  let offAction = try? ActionRef(dto: w.object.offAction),
                  let setAction = try? ActionRef(dto: w.object.setValueAction)
            else { return [] }
            return [.dimmableLight(DimmableLightDescriptor(
                id: "\(w.id)_0", name: w.label,
                state: ValueRef(dto: w.object.value),
                min: w.min, max: w.max, precision: w.precision,
                onAction: onAction, offAction: offAction, setValueAction: setAction))]

        case .led(let w):
            return hsbLight(for: w).map { [.hsbLight($0)] } ?? []

        case .contactSensor(let w):
            var result: [EntityDescriptor] = [.contactSensor(ContactSensorDescriptor(
                id: "\(w.id)_binary_sensor", name: w.label,
                state: ValueRef(dto: w.object.value),
                reversed: w.reverseState,
                onIndication: w.onIndication, offIndication: w.offIndication))]
            if let clickDto = w.object.clickAction, let click = try? ActionRef(dto: clickDto) {
                result.append(.trigger(TriggerDescriptor(
                    id: "\(w.id)_button", name: w.label, action: click)))
            }
            return result

        case .contactSensorDouble(let w):
            // Suffix contract of the reference mapper (spec §6.3.4).
            var result: [EntityDescriptor] = []
            for (component, side) in [(w.componentLeft, "left"), (w.componentRight, "right")] {
                result.append(.contactSensor(ContactSensorDescriptor(
                    id: "\(w.id)_binary_sensor_\(side)", name: component.label,
                    state: ValueRef(dto: component.object.value),
                    reversed: component.reverseState,
                    onIndication: component.onIndication,
                    offIndication: component.offIndication)))
                if let clickDto = component.object.clickAction,
                   let click = try? ActionRef(dto: clickDto) {
                    result.append(.trigger(TriggerDescriptor(
                        id: "\(w.id)_button_\(side)", name: component.label, action: click)))
                }
            }
            return result

        case .slider(let w):
            guard let setAction = try? ActionRef(dto: w.object.setValueAction) else { return [] }
            var result: [EntityDescriptor] = [.numberSetting(NumberSettingDescriptor(
                id: "\(w.id)_slider", name: w.label,
                state: ValueRef(dto: w.object.value),
                setValueAction: setAction,
                min: w.min, max: w.max, precision: w.precision))]
            if let clickDto = w.object.clickAction, let click = try? ActionRef(dto: clickDto) {
                result.append(.trigger(TriggerDescriptor(
                    id: "\(w.id)_button", name: w.label, action: click)))
            }
            return result

        case .multisensor(let w):
            // Fixed channel set with canonical kinds/units (spec §6.3.6).
            let channels: [(String, SensorKind, MultisensorObjectDTO)] = [
                ("air_co2", .co2, w.objectAirCo2),
                ("sound", .soundPressure, w.objectSound),
                ("air_voc", .voc, w.objectAirVoc),
                ("light", .illuminance, w.objectLight),
                ("pressure", .pressure, w.objectPressure),
                ("humidity", .humidity, w.objectHumidity),
                ("temperature", .temperature, w.objectTemperature),
            ]
            return channels.map { suffix, kind, object in
                .sensor(SensorDescriptor(
                    id: "\(w.id)_\(suffix)", name: w.label,
                    state: ValueRef(dto: object.value),
                    kind: kind, grentonUnit: nil, valueType: nil, precision: nil))
            }

        case .rollerShutter(let w):
            // Completeness (spec §6.3.9 Δ): needs a component with an action.
            guard let component = w.components.first,
                  let actionDto = component.actions.first,
                  let action = try? ActionRef(dto: actionDto)
            else { return [] }
            return [
                .stateSensor(StateSensorDescriptor(
                    id: "\(w.id)_sensor", name: component.label,
                    state: ValueRef(dto: component.state))),
                .trigger(TriggerDescriptor(
                    id: "\(w.id)_button", name: component.label, action: action)),
            ]

        case .rollerShutterV3(let w):
            guard let setPosition = try? ActionRef(dto: w.object.setPositionAction) else { return [] }
            // Tilt present ⇔ lamelMoveTimeout present (reference heuristic,
            // spec §6.3.8); stop present ⇔ stopAction present.
            var tilt: CoverDescriptor.Tilt?
            if w.object.lamelMoveTimeout != nil,
               let setTilt = try? ActionRef(dto: w.object.setLamelPositionAction) {
                tilt = CoverDescriptor.Tilt(
                    position: ValueRef(dto: w.object.lamelPosition), setAction: setTilt)
            }
            let stop = w.object.stopAction.flatMap { try? ActionRef(dto: $0) }
            // Id = widget id, NO suffix (reference unique_id contract).
            return [.cover(CoverDescriptor(
                id: w.id, name: w.label,
                motionState: ValueRef(dto: w.object.state),
                position: ValueRef(dto: w.object.position),
                setPositionAction: setPosition,
                tilt: tilt, stopAction: stop))]

        case .camera(let w):
            // Completeness (spec §6.3.11 Δ): needs a stream component.
            guard let component = w.components.first else { return [] }
            return [.camera(CameraDescriptor(
                id: "\(w.id)_0", name: component.label, streamURL: component.value))]

        case .scene(let w):
            return w.components.compactMap { component in
                sceneTrigger(id: "\(w.id)_\(component.rowId)", component: component)
            }

        case .sceneDouble(let w):
            // rowId repeats (both 0 in practice) — suffix by list position.
            return w.components.enumerated().compactMap { position, component in
                sceneTrigger(id: "\(w.id)_\(position)", component: component)
            }

        case .thermostatV2(let w):
            let o = w.object
            guard let setTarget = try? ActionRef(dto: o.setTargetTemperatureAction) else { return [] }
            func control(_ state: ValueRefDTO?, _ action: ActionRefDTO?) -> ThermostatDescriptor.Control? {
                guard let state, let action, let setAction = try? ActionRef(dto: action) else { return nil }
                return ThermostatDescriptor.Control(state: ValueRef(dto: state), setAction: setAction)
            }
            return [.thermostat(ThermostatDescriptor(
                id: "\(w.id)_0", name: w.label,
                currentTemperature: ValueRef(dto: o.currentTemperature),
                targetTemperature: ValueRef(dto: o.targetTemperature),
                setTargetTemperatureAction: setTarget,
                minTemperature: o.minTemperature.map(ValueRef.init(dto:)),
                maxTemperature: o.maxTemperature.map(ValueRef.init(dto:)),
                mode: control(o.mode, o.setModeAction),
                power: control(o.state, o.setStateAction),
                output: o.controlOutValue.map(ValueRef.init(dto:))))]

        case .eventScheduler(let w):
            let o = w.object
            guard let add = try? ActionRef(dto: o.addRuleAction),
                  let delete = try? ActionRef(dto: o.deleteRuleAction) else { return [] }
            func optional(_ action: ActionRefDTO?) -> ActionRef? { action.flatMap { try? ActionRef(dto: $0) } }
            return [.eventSchedule(EventScheduleDescriptor(
                id: "\(w.id)_0", name: w.label,
                state: ValueRef(dto: o.state), ruleList: ValueRef(dto: o.ruleList),
                addRuleAction: add, deleteRuleAction: delete,
                ruleCount: o.ruleCount.map(ValueRef.init(dto:)), ruleSpace: o.ruleSpace.map(ValueRef.init(dto:)),
                nextRule: o.nextRule.map(ValueRef.init(dto:)), currentRule: o.currentRule.map(ValueRef.init(dto:)),
                startAction: optional(o.startAction), stopAction: optional(o.stopAction),
                enableRuleAction: optional(o.enableRuleAction), disableRuleAction: optional(o.disableRuleAction)))]

        case .tvRemoteControl(let w):
            // Names outside the catalog and entries that are not actions
            // are left out; the entity exists even with none (spec §6.3.14).
            var buttons: [TvRemoteButton: ActionRef] = [:]
            for (name, dto) in w.buttons {
                guard let button = TvRemoteButton(rawValue: name), let action = try? ActionRef(dto: dto) else { continue }
                buttons[button] = action
            }
            return [.tvRemote(TvRemoteDescriptor(id: "\(w.id)_0", name: w.label, vodLabel: w.vodLabel, buttons: buttons))]
        }
    }

    /// Only a CLICK action of type SCRIPT qualifies (spec §6.3.10).
    private static func sceneTrigger(id: String, component: ButtonMonostableComponentDTO) -> EntityDescriptor? {
        let script = component.actions.lazy
            .compactMap { try? ActionRef(dto: $0) }
            .first { $0.event == .click && $0.call == .script }
        guard let script else { return nil }
        return .sceneTrigger(SceneTriggerDescriptor(id: id, name: component.label, action: script))
    }

    /// Shared ON_OFF / ON_OFF_DOUBLE component mapping: both the ON and the
    /// OFF action must be present or the component is skipped (spec §6.3.1).
    private static func toggle(
        widgetId: String, label: String, rowId: Int,
        state: ValueRefDTO, actions: [ActionRefDTO],
        onIndication: String, offIndication: String
    ) -> EntityDescriptor? {
        var onAction: ActionRef?
        var offAction: ActionRef?
        for dto in actions {
            guard let action = try? ActionRef(dto: dto) else { continue }
            switch action.event {
            case .on: onAction = onAction ?? action
            case .off: offAction = offAction ?? action
            case .click: break
            }
        }
        guard let onAction, let offAction else { return nil }
        return .toggle(ToggleDescriptor(
            id: "\(widgetId)_\(rowId)", name: label,
            state: ValueRef(dto: state),
            onAction: onAction, offAction: offAction,
            onIndication: onIndication, offIndication: offIndication))
    }

    /// LED completeness (spec §6.3.3): all four components plus ON and OFF
    /// on the button; slider actions are each component's FIRST action.
    private static func hsbLight(for widget: LedWidgetDTO) -> HsbLightDescriptor? {
        var button: LedButtonComponentDTO?
        var hue: LedSliderComponentDTO?
        var saturation: LedSliderComponentDTO?
        var brightness: LedSliderComponentDTO?

        for component in widget.components {
            switch component {
            case .button(let c): button = button ?? c
            case .hue(let c): hue = hue ?? c
            case .saturation(let c): saturation = saturation ?? c
            case .brightness(let c): brightness = brightness ?? c
            }
        }
        guard let button, let hue, let saturation, let brightness else { return nil }

        var onAction: ActionRef?
        var offAction: ActionRef?
        for dto in button.actions {
            guard let action = try? ActionRef(dto: dto) else { continue }
            if action.event == .on { onAction = onAction ?? action }
            if action.event == .off { offAction = offAction ?? action }
        }
        guard let onAction, let offAction else { return nil }

        func channel(_ component: LedSliderComponentDTO) -> HsbChannelDescriptor? {
            guard let firstAction = component.actions.first,
                  let action = try? ActionRef(dto: firstAction)
            else { return nil }
            return HsbChannelDescriptor(
                state: ValueRef(dto: component.state),
                setAction: action,
                range: ChannelRange(min: Double(component.range.min), max: Double(component.range.max)))
        }
        guard let hueChannel = channel(hue),
              let saturationChannel = channel(saturation),
              let brightnessChannel = channel(brightness)
        else { return nil }

        return HsbLightDescriptor(
            id: "\(widget.id)_0", name: button.label,
            powerState: ValueRef(dto: button.state),
            onAction: onAction, offAction: offAction,
            hue: hueChannel, saturation: saturationChannel, brightness: brightnessChannel)
    }
}
