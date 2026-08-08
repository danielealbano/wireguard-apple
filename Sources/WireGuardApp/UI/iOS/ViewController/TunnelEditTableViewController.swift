// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import UIKit
import UniformTypeIdentifiers

protocol TunnelEditTableViewControllerDelegate: AnyObject {
    func tunnelSaved(tunnel: TunnelContainer)
    func tunnelEditingCancelled()
}

class TunnelEditTableViewController: UITableViewController {
    private enum Section {
        case interface
        case peer(_ peer: TunnelViewModel.PeerData)
        case addPeer
        case onDemand

        static func == (lhs: Section, rhs: Section) -> Bool {
            switch (lhs, rhs) {
            case (.interface, .interface),
                 (.addPeer, .addPeer),
                 (.onDemand, .onDemand):
                return true
            case let (.peer(peerA), .peer(peerB)):
                return peerA.index == peerB.index
            default:
                return false
            }
        }
    }

    weak var delegate: TunnelEditTableViewControllerDelegate?

    let interfaceFieldsBySection: [[TunnelViewModel.InterfaceField]] = [
        [.name],
        [.privateKey, .publicKey, .generateKeyPair],
        [.addresses, .listenPort, .mtu, .dns]
    ]

    func peerFieldsToShow(for peerData: TunnelViewModel.PeerData) -> [TunnelViewModel.PeerField] {
        var fields: [TunnelViewModel.PeerField] = [.publicKey, .preSharedKey, .endpoint, .wsMode]
        if !peerData[.wsMode].isEmpty {
            fields.append(contentsOf: TunnelViewModel.PeerData.wsParameterFields)
        }
        fields.append(.allowedIPs)
        if peerData.shouldAllowExcludePrivateIPsControl {
            fields.append(.excludePrivateIPs)
        }
        fields.append(contentsOf: [.persistentKeepAlive, .deletePeer])
        return fields
    }

    let onDemandFields: [ActivateOnDemandViewModel.OnDemandField] = [
        .nonWiFiInterface,
        .wiFiInterface,
        .ssid
    ]

    let tunnelsManager: TunnelsManager
    let tunnel: TunnelContainer?
    let tunnelViewModel: TunnelViewModel
    var onDemandViewModel: ActivateOnDemandViewModel
    private var sections = [Section]()
    private var pendingWsFilePeer: TunnelViewModel.PeerData?
    private var pendingWsFileField: TunnelViewModel.PeerField?

    // Use this initializer to edit an existing tunnel.
    init(tunnelsManager: TunnelsManager, tunnel: TunnelContainer) {
        self.tunnelsManager = tunnelsManager
        self.tunnel = tunnel
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: tunnel.tunnelConfiguration)
        onDemandViewModel = ActivateOnDemandViewModel(tunnel: tunnel)
        super.init(style: .grouped)
        loadSections()
    }

    // Use this initializer to create a new tunnel.
    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        tunnel = nil
        tunnelViewModel = TunnelViewModel(tunnelConfiguration: nil)
        onDemandViewModel = ActivateOnDemandViewModel()
        super.init(style: .grouped)
        loadSections()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tunnel == nil ? tr("newTunnelViewTitle") : tr("editTunnelViewTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension

        tableView.register(TunnelEditKeyValueCell.self)
        tableView.register(TunnelEditEditableKeyValueCell.self)
        tableView.register(ButtonCell.self)
        tableView.register(SwitchCell.self)
        tableView.register(ChevronCell.self)
    }

    private func loadSections() {
        sections.removeAll()
        interfaceFieldsBySection.forEach { _ in sections.append(.interface) }
        tunnelViewModel.peersData.forEach { sections.append(.peer($0)) }
        sections.append(.addPeer)
        sections.append(.onDemand)
    }

    @objc func saveTapped() {
        tableView.endEditing(false)
        let tunnelSaveResult = tunnelViewModel.save()
        switch tunnelSaveResult {
        case .error(let errorMessage):
            let alertTitle = (tunnelViewModel.interfaceData.validatedConfiguration == nil || tunnelViewModel.interfaceData.validatedName == nil) ?
                tr("alertInvalidInterfaceTitle") : tr("alertInvalidPeerTitle")
            ErrorPresenter.showErrorAlert(title: alertTitle, message: errorMessage, from: self)
            tableView.reloadData() // Highlight erroring fields
        case .saved(let tunnelConfiguration):
            let onDemandOption = onDemandViewModel.toOnDemandOption()
            if let tunnel = tunnel {
                // We're modifying an existing tunnel
                tunnelsManager.modify(tunnel: tunnel, tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] error in
                    if let error = error {
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    } else {
                        self?.dismiss(animated: true, completion: nil)
                        self?.delegate?.tunnelSaved(tunnel: tunnel)
                    }
                }
            } else {
                // We're adding a new tunnel
                tunnelsManager.add(tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] result in
                    switch result {
                    case .failure(let error):
                        ErrorPresenter.showErrorAlert(error: error, from: self)
                    case .success(let tunnel):
                        self?.dismiss(animated: true, completion: nil)
                        self?.delegate?.tunnelSaved(tunnel: tunnel)
                    }
                }
            }
        }
    }

    @objc func cancelTapped() {
        dismiss(animated: true, completion: nil)
        delegate?.tunnelEditingCancelled()
    }
}

// MARK: UITableViewDataSource

extension TunnelEditTableViewController {
    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .interface:
            return interfaceFieldsBySection[section].count
        case .peer(let peerData):
            return peerFieldsToShow(for: peerData).count
        case .addPeer:
            return 1
        case .onDemand:
            if onDemandViewModel.isWiFiInterfaceEnabled {
                return 3
            } else {
                return 2
            }
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .interface:
            return section == 0 ? tr("tunnelSectionTitleInterface") : nil
        case .peer:
            return tr("tunnelSectionTitlePeer")
        case .addPeer:
            return nil
        case .onDemand:
            return tr("tunnelSectionTitleOnDemand")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .interface:
            return interfaceFieldCell(for: tableView, at: indexPath)
        case .peer(let peerData):
            return peerCell(for: tableView, at: indexPath, with: peerData)
        case .addPeer:
            return addPeerCell(for: tableView, at: indexPath)
        case .onDemand:
            return onDemandCell(for: tableView, at: indexPath)
        }
    }

    private func interfaceFieldCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = interfaceFieldsBySection[indexPath.section][indexPath.row]
        switch field {
        case .generateKeyPair:
            return generateKeyPairCell(for: tableView, at: indexPath, with: field)
        case .publicKey:
            return publicKeyCell(for: tableView, at: indexPath, with: field)
        default:
            return interfaceFieldKeyValueCell(for: tableView, at: indexPath, with: field)
        }
    }

    private func generateKeyPairCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = field.localizedUIString
        cell.onTapped = { [weak self] in
            guard let self = self else { return }

            self.tunnelViewModel.interfaceData[.privateKey] = PrivateKey().base64Key
            if let privateKeyRow = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .privateKey),
                let publicKeyRow = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .publicKey) {
                let privateKeyIndex = IndexPath(row: privateKeyRow, section: indexPath.section)
                let publicKeyIndex = IndexPath(row: publicKeyRow, section: indexPath.section)
                self.tableView.reloadRows(at: [privateKeyIndex, publicKeyIndex], with: .fade)
            }
        }
        return cell
    }

    private func publicKeyCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: TunnelEditKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString
        cell.value = tunnelViewModel.interfaceData[field]
        return cell
    }

    private func interfaceFieldKeyValueCell(for tableView: UITableView, at indexPath: IndexPath, with field: TunnelViewModel.InterfaceField) -> UITableViewCell {
        let cell: TunnelEditEditableKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString

        switch field {
        case .name, .privateKey:
            cell.placeholderText = tr("tunnelEditPlaceholderTextRequired")
            cell.keyboardType = .default
        case .addresses:
            cell.placeholderText = tr("tunnelEditPlaceholderTextStronglyRecommended")
            cell.keyboardType = .numbersAndPunctuation
        case .dns:
            cell.placeholderText = tunnelViewModel.peersData.contains(where: { $0.shouldStronglyRecommendDNS }) ? tr("tunnelEditPlaceholderTextStronglyRecommended") : tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .numbersAndPunctuation
        case .listenPort, .mtu:
            cell.placeholderText = tr("tunnelEditPlaceholderTextAutomatic")
            cell.keyboardType = .numberPad
        case .publicKey, .generateKeyPair:
            cell.keyboardType = .default
        case .status, .toggleStatus:
            fatalError("Unexpected interface field")
        }

        cell.isValueValid = (!tunnelViewModel.interfaceData.fieldsWithError.contains(field))
        // Bind values to view model
        cell.value = tunnelViewModel.interfaceData[field]
        if field == .dns { // While editing DNS, you might directly set exclude private IPs
            cell.onValueBeingEdited = { [weak self] value in
                self?.tunnelViewModel.interfaceData[field] = value
            }
            cell.onValueChanged = { [weak self] oldValue, newValue in
                guard let self = self else { return }
                let isAllowedIPsChanged = self.tunnelViewModel.updateDNSServersInAllowedIPsIfRequired(oldDNSServers: oldValue, newDNSServers: newValue)
                if isAllowedIPsChanged {
                    let section = self.sections.firstIndex { if case .peer = $0 { return true } else { return false } }
                    if let section = section, case .peer(let peerData) = self.sections[section],
                       let row = self.peerFieldsToShow(for: peerData).firstIndex(of: .allowedIPs) {
                        self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
                    }
                }
            }
        } else {
            cell.onValueChanged = { [weak self] _, value in
                self?.tunnelViewModel.interfaceData[field] = value
            }
        }
        // Compute public key live
        if field == .privateKey {
            cell.onValueBeingEdited = { [weak self] value in
                guard let self = self else { return }

                self.tunnelViewModel.interfaceData[.privateKey] = value
                if let row = self.interfaceFieldsBySection[indexPath.section].firstIndex(of: .publicKey) {
                    self.tableView.reloadRows(at: [IndexPath(row: row, section: indexPath.section)], with: .none)
                }
            }
        }
        return cell
    }

    private func peerCell(for tableView: UITableView, at indexPath: IndexPath, with peerData: TunnelViewModel.PeerData) -> UITableViewCell {
        let field = peerFieldsToShow(for: peerData)[indexPath.row]

        switch field {
        case .deletePeer:
            return deletePeerCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .excludePrivateIPs:
            return excludePrivateIPsCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsMode:
            return wsModeCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsMask, .wsTlsInsecure:
            return wsSwitchCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        case .wsTlsCa, .wsTlsCert, .wsTlsKey:
            return wsFileCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        default:
            return peerFieldKeyValueCell(for: tableView, at: indexPath, peerData: peerData, field: field)
        }
    }

    private func wsModeCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.detailMessage = wsModeLocalizedDescription(peerData[.wsMode])
        return cell
    }

    private func wsModeLocalizedDescription(_ wireValue: String) -> String {
        switch wireValue {
        case WsMode.websocket.rawValue: return tr("tunnelPeerWsModeWebsocket")
        case WsMode.wstunnel.rawValue: return tr("tunnelPeerWsModeWstunnel")
        default: return tr("tunnelPeerWsModeNone")
        }
    }

    private func wsSwitchCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.isOn = peerData[field] == "true"
        cell.onSwitchToggled = { [weak peerData] isOn in
            peerData?[field] = isOn ? "true" : ""
        }
        return cell
    }

    private func wsFileCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        let value = peerData[field]
        cell.detailMessage = value.isEmpty ? tr("tunnelEditSelectFile") : (value as NSString).lastPathComponent
        return cell
    }

    private func showWsModeActionSheet(for peerData: TunnelViewModel.PeerData, at indexPath: IndexPath) {
        let alert = UIAlertController(title: tr("tunnelPeerWsMode"), message: nil, preferredStyle: .actionSheet)
        let options: [(String, String)] = [
            (tr("tunnelPeerWsModeNone"), ""),
            (tr("tunnelPeerWsModeWebsocket"), WsMode.websocket.rawValue),
            (tr("tunnelPeerWsModeWstunnel"), WsMode.wstunnel.rawValue)
        ]
        for (title, wireValue) in options {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self, weak peerData] _ in
                guard let self = self, let peerData = peerData else { return }
                peerData[.wsMode] = wireValue
                if wireValue.isEmpty {
                    // Back to UDP: drop the now-hidden WS parameter values, or save() would
                    // reject them via the presence checks with no visible field to fix.
                    peerData.clearWsParameterFields()
                }
                self.tableView.reloadSections(IndexSet(integer: indexPath.section), with: .fade)
            })
        }
        alert.addAction(UIAlertAction(title: tr("actionCancel"), style: .cancel, handler: nil))
        if let popoverPresentationController = alert.popoverPresentationController {
            popoverPresentationController.sourceView = tableView.cellForRow(at: indexPath) ?? tableView
            popoverPresentationController.sourceRect = (tableView.cellForRow(at: indexPath) ?? tableView).bounds
        }
        present(alert, animated: true)
    }

    private func showWsFilePicker(for peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) {
        pendingWsFilePeer = peerData
        pendingWsFileField = field
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func deletePeerCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = field.localizedUIString
        cell.hasDestructiveAction = true
        cell.onTapped = { [weak self, weak peerData] in
            guard let self = self, let peerData = peerData else { return }
            ConfirmationAlertPresenter.showConfirmationAlert(message: tr("deletePeerConfirmationAlertMessage"),
                                                             buttonTitle: tr("deletePeerConfirmationAlertButtonTitle"),
                                                             from: cell, presentingVC: self) { [weak self] in
                guard let self = self else { return }
                let removedSectionIndices = self.deletePeer(peer: peerData)
                let shouldShowExcludePrivateIPs = (self.tunnelViewModel.peersData.count == 1 && self.tunnelViewModel.peersData[0].shouldAllowExcludePrivateIPsControl)

                // swiftlint:disable:next trailing_closure
                tableView.performBatchUpdates({
                    self.tableView.deleteSections(removedSectionIndices, with: .fade)
                    if shouldShowExcludePrivateIPs {
                        if let firstPeerData = self.tunnelViewModel.peersData.first,
                           let row = self.peerFieldsToShow(for: firstPeerData).firstIndex(of: .excludePrivateIPs) {
                            let rowIndexPath = IndexPath(row: row, section: self.interfaceFieldsBySection.count /* First peer section */)
                            self.tableView.insertRows(at: [rowIndexPath], with: .fade)
                        }
                    }
                })
            }
        }
        return cell
    }

    private func excludePrivateIPsCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = field.localizedUIString
        cell.isEnabled = peerData.shouldAllowExcludePrivateIPsControl
        cell.isOn = peerData.excludePrivateIPsValue
        cell.onSwitchToggled = { [weak self] isOn in
            guard let self = self else { return }
            peerData.excludePrivateIPsValueChanged(isOn: isOn, dnsServers: self.tunnelViewModel.interfaceData[.dns])
            if let row = self.peerFieldsToShow(for: peerData).firstIndex(of: .allowedIPs) {
                self.tableView.reloadRows(at: [IndexPath(row: row, section: indexPath.section)], with: .none)
            }
        }
        return cell
    }

    private func peerFieldKeyValueCell(for tableView: UITableView, at indexPath: IndexPath, peerData: TunnelViewModel.PeerData, field: TunnelViewModel.PeerField) -> UITableViewCell {
        let cell: TunnelEditEditableKeyValueCell = tableView.dequeueReusableCell(for: indexPath)
        cell.key = field.localizedUIString

        switch field {
        case .publicKey:
            cell.placeholderText = tr("tunnelEditPlaceholderTextRequired")
            cell.keyboardType = .default
        case .preSharedKey, .endpoint:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .default
        case .allowedIPs:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .numbersAndPunctuation
        case .persistentKeepAlive:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOff")
            cell.keyboardType = .numberPad
        case .wstunnelTarget, .wsBearer:
            cell.placeholderText = tr("tunnelEditPlaceholderTextOptional")
            cell.keyboardType = .default
        case .wsPingInterval, .wsBackoffMin, .wsBackoffMax:
            cell.placeholderText = tr("tunnelEditPlaceholderTextAutomatic")
            cell.keyboardType = .numberPad
        case .excludePrivateIPs, .deletePeer:
            cell.keyboardType = .default
        case .wsMode, .wsMask, .wsTlsCa, .wsTlsCert, .wsTlsKey, .wsTlsInsecure:
            fatalError()
        case .rxBytes, .txBytes, .lastHandshakeTime:
            fatalError()
        }

        cell.isValueValid = !peerData.fieldsWithError.contains(field)
        cell.value = peerData[field]

        if field == .allowedIPs {
            let firstInterfaceSection = sections.firstIndex { $0 == .interface }!
            let interfaceSubSection = interfaceFieldsBySection.firstIndex { $0.contains(.dns) }!
            let dnsRow = interfaceFieldsBySection[interfaceSubSection].firstIndex { $0 == .dns }!

            cell.onValueBeingEdited = { [weak self, weak peerData] value in
                guard let self = self, let peerData = peerData else { return }

                let oldValue = peerData.shouldAllowExcludePrivateIPsControl
                peerData[.allowedIPs] = value
                // `.excludePrivateIPs` sits directly after `.allowedIPs` in the built list, so
                // both the insert and the delete index derive from the current list.
                if oldValue != peerData.shouldAllowExcludePrivateIPsControl,
                   let allowedIPsRow = self.peerFieldsToShow(for: peerData).firstIndex(of: .allowedIPs) {
                    let excludeRow = allowedIPsRow + 1
                    if peerData.shouldAllowExcludePrivateIPsControl {
                        self.tableView.insertRows(at: [IndexPath(row: excludeRow, section: indexPath.section)], with: .fade)
                    } else {
                        self.tableView.deleteRows(at: [IndexPath(row: excludeRow, section: indexPath.section)], with: .fade)
                    }
                }

                tableView.reloadRows(at: [IndexPath(row: dnsRow, section: firstInterfaceSection + interfaceSubSection)], with: .none)
            }
        } else {
            cell.onValueChanged = { [weak peerData] _, value in
                peerData?[field] = value
            }
        }

        return cell
    }

    private func addPeerCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
        cell.buttonText = tr("addPeerButtonTitle")
        cell.onTapped = { [weak self] in
            guard let self = self else { return }
            let shouldHideExcludePrivateIPs = (self.tunnelViewModel.peersData.count == 1 && self.tunnelViewModel.peersData[0].shouldAllowExcludePrivateIPsControl)
            let addedSectionIndices = self.appendEmptyPeer()
            tableView.performBatchUpdates({
                tableView.insertSections(addedSectionIndices, with: .fade)
                // The control is no longer in the first peer's built list; it sat directly
                // after `.allowedIPs`, so that index + 1 is the removed row.
                if shouldHideExcludePrivateIPs, let firstPeerData = self.tunnelViewModel.peersData.first,
                   let allowedIPsRow = self.peerFieldsToShow(for: firstPeerData).firstIndex(of: .allowedIPs) {
                    let rowIndexPath = IndexPath(row: allowedIPsRow + 1, section: self.interfaceFieldsBySection.count /* First peer section */)
                    self.tableView.deleteRows(at: [rowIndexPath], with: .fade)
                }
            }, completion: nil)
        }
        return cell
    }

    private func onDemandCell(for tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let field = onDemandFields[indexPath.row]
        if indexPath.row < 2 {
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.isOn = onDemandViewModel.isEnabled(field: field)
            cell.onSwitchToggled = { [weak self] isOn in
                guard let self = self else { return }
                self.onDemandViewModel.setEnabled(field: field, isEnabled: isOn)
                let section = self.sections.firstIndex { $0 == .onDemand }!
                let indexPath = IndexPath(row: 2, section: section)
                if field == .wiFiInterface {
                    if isOn {
                        tableView.insertRows(at: [indexPath], with: .fade)
                    } else {
                        tableView.deleteRows(at: [indexPath], with: .fade)
                    }
                }
            }
            return cell
        } else {
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.detailMessage = onDemandViewModel.localizedSSIDDescription
            return cell
        }
    }

    func appendEmptyPeer() -> IndexSet {
        tunnelViewModel.appendEmptyPeer()
        loadSections()
        let addedPeerIndex = tunnelViewModel.peersData.count - 1
        return IndexSet(integer: interfaceFieldsBySection.count + addedPeerIndex)
    }

    func deletePeer(peer: TunnelViewModel.PeerData) -> IndexSet {
        tunnelViewModel.deletePeer(peer: peer)
        loadSections()
        return IndexSet(integer: interfaceFieldsBySection.count + peer.index)
    }
}

extension TunnelEditTableViewController {
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        switch sections[indexPath.section] {
        case .onDemand:
            return indexPath.row == 2 ? indexPath : nil
        case .peer(let peerData):
            switch peerFieldsToShow(for: peerData)[indexPath.row] {
            case .wsMode, .wsTlsCa, .wsTlsCert, .wsTlsKey:
                return indexPath
            default:
                return nil
            }
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section] {
        case .onDemand:
            assert(indexPath.row == 2)
            tableView.deselectRow(at: indexPath, animated: true)
            let ssidOptionVC = SSIDOptionEditTableViewController(option: onDemandViewModel.ssidOption, ssids: onDemandViewModel.selectedSSIDs)
            ssidOptionVC.delegate = self
            navigationController?.pushViewController(ssidOptionVC, animated: true)
        case .peer(let peerData):
            tableView.deselectRow(at: indexPath, animated: true)
            switch peerFieldsToShow(for: peerData)[indexPath.row] {
            case .wsMode:
                showWsModeActionSheet(for: peerData, at: indexPath)
            case .wsTlsCa, .wsTlsCert, .wsTlsKey:
                showWsFilePicker(for: peerData, field: peerFieldsToShow(for: peerData)[indexPath.row])
            default:
                assertionFailure()
            }
        default:
            assertionFailure()
        }
    }
}

extension TunnelEditTableViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let peerData = pendingWsFilePeer
        let field = pendingWsFileField
        pendingWsFilePeer = nil
        pendingWsFileField = nil
        guard let url = urls.first, let peerData = peerData, let field = field else { return }
        // The picked URL can be a non-local file-provider item whose copy blocks on a download —
        // never on the main thread (same pattern as TunnelImporter).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileManager.importWsTlsFile(from: url) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let destination):
                    peerData[field] = destination.path
                    self.tableView.reloadData()
                case .failure(let error):
                    self.showWsFileImportError(error)
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingWsFilePeer = nil
        pendingWsFileField = nil
    }

    private func showWsFileImportError(_ error: Error) {
        // Shared code stays tr()-free (the NE must not see it), so the localized mapping
        // lives here: surface the underlying Cocoa error's localized message.
        let message: String
        switch error {
        case FileManager.WsTlsImportError.noAppGroupContainer:
            message = tr("alertWsFileImportFailedNoContainerMessage")
        case FileManager.WsTlsImportError.copyFailed(let underlyingError):
            message = tr(format: "alertWsFileImportFailedMessage (%@)", underlyingError.localizedDescription)
        default:
            message = tr(format: "alertWsFileImportFailedMessage (%@)", error.localizedDescription)
        }
        ErrorPresenter.showErrorAlert(title: tr("alertWsFileImportFailedTitle"), message: message, from: self)
    }
}

extension TunnelEditTableViewController: SSIDOptionEditTableViewControllerDelegate {
    func ssidOptionSaved(option: ActivateOnDemandViewModel.OnDemandSSIDOption, ssids: [String]) {
        onDemandViewModel.selectedSSIDs = ssids
        onDemandViewModel.ssidOption = option
        onDemandViewModel.fixSSIDOption()
        if let onDemandSection = sections.firstIndex(where: { $0 == .onDemand }) {
            if let ssidRowIndex = onDemandFields.firstIndex(of: .ssid) {
                let indexPath = IndexPath(row: ssidRowIndex, section: onDemandSection)
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        }
    }
}
