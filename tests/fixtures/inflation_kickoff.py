import pytest


ADMIN_DELAY = 3 * 86400


@pytest.fixture
def inflation_kickoff(
    minter,
    inflation_manager,
    address_provider,
    admin,
    pool,
    mockKeeperGauge,
    mockAmmGauge,
    lpToken,
    mockAmmToken,
    lpGauge,
    topUpActionFeeHandler,
):
    # Set the minter and add all the
    inflation_manager.setMinter(minter, {"from": admin})
    inflation_manager.setKeeperGauge(pool, mockKeeperGauge, {"from": admin})
    inflation_manager.setAmmGauge(mockAmmToken, mockAmmGauge, {"from": admin})
    address_provider.addPool(pool, {"from": admin})

    # Set all the weights for the Gauges and stakerVault
    inflation_manager.updateLpPoolWeight(lpToken, 0.4 * 1e18, {"from": admin})
    inflation_manager.updateKeeperPoolWeight(pool, 0.4 * 1e18, {"from": admin})
    inflation_manager.updateAmmTokenWeight(mockAmmToken, 0.4 * 1e18, {"from": admin})

    topUpActionFeeHandler.setInitialKeeperGaugeForToken(
        lpToken, mockKeeperGauge, {"from": admin}
    )
