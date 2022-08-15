from brownie.test.managers.runner import RevertContextManager as reverts
import pytest

from support.constants import Roles

pytestmark = pytest.mark.usefixtures("setup_controller")


@pytest.fixture
def otherMockAmmGauge(admin, MockAmmGauge, address_provider, bob):
    return admin.deploy(MockAmmGauge, address_provider, bob)


@pytest.fixture
def otherMockKeeperGauge(admin, MockKeeperGauge, address_provider, pool):
    return admin.deploy(MockKeeperGauge, address_provider, pool)


@pytest.fixture
def setup_controller(
    inflation_manager,
    address_provider,
    admin,
    mockKeeperGauge,
    otherMockKeeperGauge,
    minter,
    pool,
    cappedPool,
):
    inflation_manager.setKeeperGauge(pool, mockKeeperGauge, {"from": admin})
    inflation_manager.setKeeperGauge(cappedPool, otherMockKeeperGauge, {"from": admin})
    inflation_manager.setMinter(minter, {"from": admin})
    address_provider.addPool(pool, {"from": admin})
    address_provider.addPool(cappedPool, {"from": admin})


def test_set_keeper_pool_weight(admin, inflation_manager, pool):
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.updateKeeperPoolWeight(pool, 0.3 * 1e18, {"from": admin})
    assert inflation_manager.totalKeeperPoolWeight() == 0.3 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 0.3 * 1e18


def test_set_keeper_pool_weight_larger_one(admin, inflation_manager, minter, pool):
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.updateKeeperPoolWeight(pool, 2 * 1e18, {"from": admin})
    assert inflation_manager.totalKeeperPoolWeight() == 2 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 2 * 1e18
    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(pool))
        == minter.getKeeperInflationRate()
    )


def test_set_keeper_pool_weight_two_pools(
    admin, inflation_manager, pool, cappedPool, lpToken, cappedLpToken
):
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.keeperPoolWeights(cappedPool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.updateKeeperPoolWeight(pool, 0.3 * 1e18, {"from": admin})
    inflation_manager.updateKeeperPoolWeight(cappedPool, 0.4 * 1e18, {"from": admin})
    assert inflation_manager.totalKeeperPoolWeight() == 0.7 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 0.3 * 1e18
    assert inflation_manager.keeperPoolWeights(cappedPool) == 0.4 * 1e18


def test_set_keeper_pool_weight_two_pools_larger_one(
    admin, inflation_manager, minter, pool, cappedPool
):
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.keeperPoolWeights(cappedPool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.updateKeeperPoolWeight(pool, 3 * 1e18, {"from": admin})
    inflation_manager.updateKeeperPoolWeight(cappedPool, 2 * 1e18, {"from": admin})
    assert inflation_manager.totalKeeperPoolWeight() == 5 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 3 * 1e18
    assert inflation_manager.keeperPoolWeights(cappedPool) == 2 * 1e18
    keeper_inflation = minter.getKeeperInflationRate()

    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(pool))
        == keeper_inflation * 0.6
    )
    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(cappedPool))
        == keeper_inflation * 0.4
    )


def test_set_lp_pool_weight(
    admin, inflation_manager, lpToken, stakerVault, minter, lpGauge
):
    assert inflation_manager.getLpPoolWeight(lpToken) == 0
    assert inflation_manager.totalLpPoolWeight() == 0
    inflation_manager.updateLpPoolWeight(lpToken, 0.3 * 1e18, {"from": admin})
    assert inflation_manager.totalLpPoolWeight() == 0.3 * 1e18
    assert inflation_manager.getLpPoolWeight(lpToken) == 0.3 * 1e18
    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == minter.getLpInflationRate()
    )


def test_set_lp_pool_weight_larger_one(
    admin, inflation_manager, lpToken, stakerVault, minter, lpGauge
):
    assert inflation_manager.getLpPoolWeight(lpToken) == 0
    assert inflation_manager.totalLpPoolWeight() == 0
    inflation_manager.updateLpPoolWeight(lpToken, 2 * 1e18, {"from": admin})
    assert inflation_manager.totalLpPoolWeight() == 2 * 1e18
    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == minter.getLpInflationRate()
    )


def test_set_lp_pool_weight_two_pools_larger_one(
    admin,
    address_provider,
    inflation_manager,
    lpToken,
    stakerVault,
    LpToken,
    StakerVault,
    minter,
    lpGauge,
    LpGauge,
    cappedLpToken,
    cappedStakerVault,
):
    otherLpGauge = admin.deploy(LpGauge, address_provider, cappedStakerVault)
    cappedStakerVault.initializeLpGauge(otherLpGauge, {"from": admin})

    assert inflation_manager.getLpPoolWeight(lpToken) == 0
    assert inflation_manager.getLpPoolWeight(cappedLpToken) == 0
    assert inflation_manager.totalLpPoolWeight() == 0
    inflation_manager.updateLpPoolWeight(lpToken, 3 * 1e18, {"from": admin})
    inflation_manager.updateLpPoolWeight(cappedLpToken, 3 * 1e18, {"from": admin})
    assert inflation_manager.totalLpPoolWeight() == 6 * 1e18
    target_inflation = 0.5 * minter.getLpInflationRate()

    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == target_inflation
    )
    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == target_inflation
    )


def test_set_lp_pool_weights_batch_two_pools_larger_one(
    admin,
    address_provider,
    inflation_manager,
    lpToken,
    stakerVault,
    minter,
    lpGauge,
    LpGauge,
    cappedLpToken,
    cappedStakerVault,
):
    otherLpGauge = admin.deploy(LpGauge, address_provider, cappedStakerVault)
    cappedStakerVault.initializeLpGauge(otherLpGauge, {"from": admin})

    assert inflation_manager.getLpPoolWeight(lpToken) == 0
    assert inflation_manager.getLpPoolWeight(cappedLpToken) == 0
    assert inflation_manager.totalLpPoolWeight() == 0
    inflation_manager.batchUpdateLpPoolWeights(
        [lpToken, cappedLpToken],
        [3 * 1e18, 3 * 1e18],
        {"from": admin},
    )
    assert inflation_manager.totalLpPoolWeight() == 6 * 1e18
    target_inflation = 0.5 * minter.getLpInflationRate()

    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == target_inflation
    )
    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(cappedStakerVault))
        == target_inflation
    )


def test_set_keeper_pool_weights_batch_two_pools_larger_one(
    admin, inflation_manager, minter, pool, cappedPool
):
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.keeperPoolWeights(cappedPool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.batchUpdateKeeperPoolWeights(
        [pool, cappedPool], [3 * 1e18, 2 * 1e18], {"from": admin}
    )
    assert inflation_manager.totalKeeperPoolWeight() == 5 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 3 * 1e18
    assert inflation_manager.keeperPoolWeights(cappedPool) == 2 * 1e18
    keeper_inflation = minter.getKeeperInflationRate()

    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(pool))
        == keeper_inflation * 0.6
    )
    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(cappedPool))
        == keeper_inflation * 0.4
    )


def test_batch_set_amm_token_weights_two_pools_larger_one(
    admin,
    inflation_manager,
    minter,
    otherMockAmmGauge,
    mockAmmGauge,
    alice,
    bob,
    mockAmmToken,
):
    inflation_manager.setAmmGauge(mockAmmToken, mockAmmGauge, {"from": admin})
    inflation_manager.setAmmGauge(bob, otherMockAmmGauge, {"from": admin})
    inflation_manager.batchUpdateAmmTokenWeights(
        [bob, mockAmmToken], [2 * 1e18, 2 * 1e18], {"from": admin}
    )
    assert inflation_manager.ammWeights(bob) == 2 * 1e18
    assert inflation_manager.ammWeights(mockAmmToken) == 2 * 1e18
    assert inflation_manager.totalAmmTokenWeight() == 4 * 1e18
    amm_inflation = minter.getAmmInflationRate()
    assert (
        pytest.approx(inflation_manager.getAmmRateForToken(bob)) == 0.5 * amm_inflation
    )
    assert (
        pytest.approx(inflation_manager.getAmmRateForToken(mockAmmToken))
        == 0.5 * amm_inflation
    )


def test_set_lp_pool_weights_batch_two_pools_larger_one_governance_proxy(
    admin,
    address_provider,
    inflation_manager,
    lpToken,
    stakerVault,
    minter,
    bob,
    lpGauge,
    LpGauge,
    cappedStakerVault,
    cappedLpToken,
    role_manager,
):
    otherLpGauge = admin.deploy(LpGauge, address_provider, cappedStakerVault)
    cappedStakerVault.initializeLpGauge(otherLpGauge, {"from": admin})

    role_manager.addGovernor(bob, {"from": admin})
    role_manager.grantRole(Roles.INFLATION_ADMIN.value, bob, {"from": admin})

    assert inflation_manager.getLpPoolWeight(lpToken) == 0
    assert inflation_manager.getLpPoolWeight(cappedLpToken) == 0
    assert inflation_manager.totalLpPoolWeight() == 0
    inflation_manager.batchUpdateLpPoolWeights(
        [lpToken, cappedLpToken],
        [3 * 1e18, 3 * 1e18],
        {"from": bob},
    )
    assert inflation_manager.totalLpPoolWeight() == 6 * 1e18
    target_inflation = 0.5 * minter.getLpInflationRate()

    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == target_inflation
    )
    assert (
        pytest.approx(inflation_manager.getLpRateForStakerVault(stakerVault))
        == target_inflation
    )


def test_set_keeper_pool_weights_batch_two_pools_larger_one_governance_proxy(
    admin, inflation_manager, minter, bob, pool, cappedPool, role_manager
):

    role_manager.addGovernor(bob, {"from": admin})
    role_manager.grantRole(Roles.INFLATION_ADMIN.value, bob, {"from": admin})
    assert inflation_manager.keeperPoolWeights(pool) == 0
    assert inflation_manager.keeperPoolWeights(cappedPool) == 0
    assert inflation_manager.totalKeeperPoolWeight() == 0
    inflation_manager.batchUpdateKeeperPoolWeights(
        [pool, cappedPool], [3 * 1e18, 2 * 1e18], {"from": admin}
    )
    assert inflation_manager.totalKeeperPoolWeight() == 5 * 1e18
    assert inflation_manager.keeperPoolWeights(pool) == 3 * 1e18
    assert inflation_manager.keeperPoolWeights(cappedPool) == 2 * 1e18
    keeper_inflation = minter.getKeeperInflationRate()

    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(pool))
        == keeper_inflation * 0.6
    )
    assert (
        pytest.approx(inflation_manager.getKeeperRateForPool(cappedPool))
        == keeper_inflation * 0.4
    )


def test_batch_set_amm_token_weights_two_pools_larger_one_governance_proxy(
    admin,
    inflation_manager,
    minter,
    otherMockAmmGauge,
    mockAmmGauge,
    alice,
    bob,
    mockAmmToken,
    role_manager,
):

    role_manager.addGovernor(bob, {"from": admin})
    role_manager.grantRole(Roles.INFLATION_ADMIN.value, bob, {"from": admin})
    inflation_manager.setAmmGauge(mockAmmToken, mockAmmGauge, {"from": admin})
    inflation_manager.setAmmGauge(bob, otherMockAmmGauge, {"from": admin})
    inflation_manager.batchUpdateAmmTokenWeights(
        [bob, mockAmmToken], [2 * 1e18, 2 * 1e18], {"from": admin}
    )

    assert inflation_manager.ammWeights(bob) == 2 * 1e18
    assert inflation_manager.ammWeights(mockAmmToken) == 2 * 1e18
    assert inflation_manager.totalAmmTokenWeight() == 4 * 1e18
    amm_inflation = minter.getAmmInflationRate()
    assert (
        pytest.approx(inflation_manager.getAmmRateForToken(bob)) == 0.5 * amm_inflation
    )
    assert (
        pytest.approx(inflation_manager.getAmmRateForToken(mockAmmToken))
        == 0.5 * amm_inflation
    )
