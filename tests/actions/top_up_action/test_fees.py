def test_updaate_action_fee(topUpAction, admin):
    assert topUpAction.actionFee() == 0
    topUpAction.updateActionFee(0.01 * 1e18, {"from": admin})
    assert topUpAction.actionFee() == 0.01 * 1e18
