def update_topup_handler(topup_action, protocol, new_handler, admin):
    topup_action.updateTopUpHandler(protocol, new_handler, {"from": admin})
