def test_update_keeper_fee(topUpActionFeeHandler, admin):
    assert topUpActionFeeHandler.keeperFeeFraction() == 0
    topUpActionFeeHandler.updateKeeperFee(0.4 * 1e18, {"from": admin})
    assert topUpActionFeeHandler.keeperFeeFraction() == 0.4 * 1e18
