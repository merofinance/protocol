import pytest


@pytest.fixture(scope="module")
def otherMockAmmToken(MockAmmToken, admin):
    return admin.deploy(MockAmmToken, "MockAmmOther", "MockAmmOther")


@pytest.fixture
def otherMockAmmGauge(admin, MockAmmGauge, address_provider, otherMockAmmToken):
    return admin.deploy(MockAmmGauge, address_provider, otherMockAmmToken)


@pytest.fixture
def otherMockKeeperGauge(admin, MockKeeperGauge, address_provider, pool):
    return admin.deploy(MockKeeperGauge, address_provider, pool)


@pytest.fixture
def inflation_kickoff(
    minter,
    controller,
    inflation_manager,
    address_provider,
    admin,
    pool,
    bob,
    mockKeeperGauge,
    mockAmmGauge,
    lpToken,
    lpGauge,
    mockAmmToken,
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


@pytest.mark.usefixtures("inflation_kickoff")
def test_change_amm_gauge_after_inflation(
    inflation_manager,
    admin,
    address_provider,
    mockAmmGauge,
    otherMockAmmGauge,
    mockAmmToken,
    MockAmmGauge,
):
    inflation_manager.removeAmmGauge(mockAmmToken, {"from": admin})
    assert inflation_manager.getAmmRateForToken(mockAmmToken) == 0
    otherMockAmmGauge = admin.deploy(MockAmmGauge, address_provider, mockAmmToken)
    inflation_manager.setAmmGauge(mockAmmToken, otherMockAmmGauge, {"from": admin})
    assert inflation_manager.getAmmRateForToken(mockAmmToken) == 0

    inflation_manager.updateAmmTokenWeight(mockAmmToken, 0.4 * 1e18, {"from": admin})
