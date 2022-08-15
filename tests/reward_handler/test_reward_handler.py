import pytest

from support.convert import format_to_bytes
from support.utils import scale

WITHDRAW_DELAY = 10 * 86400
INCREASE_DELAY = 20 * 86400


@pytest.fixture
def setup_mero_locker(meroLocker, minter, chain, meroToken, admin):
    meroLocker.initialize(1e18, 5e18, INCREASE_DELAY, WITHDRAW_DELAY)
    minter.mint_for_testing(admin, 1e18, {"from": admin})
    assert meroToken.balanceOf(admin) == 1e18
    meroToken.approve(meroLocker, 1e18, {"from": admin})
    meroLocker.lock(1e18, {"from": admin})

    chain.sleep(10)
    chain.mine()
    meroLocker.userCheckpoint(admin)


@pytest.fixture
def setup_address_provider(mockFeeBurner, address_provider, meroLocker, rewardHandler, admin):
    address_provider.initializeAddress(format_to_bytes("feeBurner", 32), mockFeeBurner, {"from": admin})
    address_provider.initializeAddress(format_to_bytes("meroLocker", 32), meroLocker, {"from": admin})
    address_provider.initializeAddress(
        format_to_bytes("rewardHandler", 32), rewardHandler, {"from": admin}
    )


@pytest.fixture
def setup_vault(admin, vault, mockStrategy):
    vault.setStrategy(mockStrategy, {"from": admin})
    vault.activateStrategy({"from": admin})
    mockStrategy.setVault(vault, {"from": admin})


@pytest.fixture(scope="module")
def vault2setup(
    admin,
    MockErc20Vault,
    MockErc20PoolSimple,
    address_provider,
    MockErc20Strategy,
    role_manager,
    MockErc20,
    controller,
    MockLpToken,
):
    underlying = admin.deploy(MockErc20, 6)
    pool = admin.deploy(MockErc20PoolSimple)
    pool.setUnderlying(underlying)
    vault = admin.deploy(MockErc20Vault, controller)
    vault.initialize(pool, 0, 0, 0, {"from": admin})
    vault.updatePerformanceFee(scale("0.5"))
    vault.updateReserveFee(0)
    vault.updateStrategistFee(0)

    strategy = admin.deploy(MockErc20Strategy, role_manager, underlying)

    vault.setStrategy(strategy, {"from": admin})
    vault.activateStrategy({"from": admin})
    strategy.setVault(vault, {"from": admin})

    lpToken = admin.deploy(MockLpToken)

    pool.setVault(vault)
    pool.setLpToken(lpToken)

    lpToken.initialize("mockLpToken", "MOCK", 6, pool, {"from": admin})
    address_provider.addPool(pool, {"from": admin})

    return vault, pool, lpToken, underlying, strategy


@pytest.fixture(scope="module")
def setup_eth_pool(admin, MockEthPool, controller, address_provider, MockLpToken):
    pool = admin.deploy(MockEthPool, controller)
    lpToken = admin.deploy(MockLpToken)
    lpToken.initialize("mockETHLpToken", "MOCKE", 18, pool, {"from": admin})
    pool.setLpToken(lpToken)
    address_provider.addPool(pool, {"from": admin})
    return pool


@pytest.fixture(scope="module")
def vault2(vault2setup):
    return vault2setup[0]


@pytest.fixture(scope="module")
def coin2(vault2setup):
    return vault2setup[3]


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider")
def test_burn_fees(rewardHandler, coin, alice, meroLocker, admin, address_provider):
    coin.mint_for_testing(rewardHandler, 100_000 * 1e18, {"from": admin})
    assert coin.balanceOf(rewardHandler) > 0

    tx = rewardHandler.burnFees({"from": alice})

    assert coin.balanceOf(rewardHandler) == 0
    assert tx.events["FeesDeposited"][0]["amount"] == 1e18
    assert tx.events["Burned"][0]["rewardToken"] == meroLocker.rewardToken()
    assert tx.events["Burned"][0]["totalAmount"] == 1e18


@pytest.mark.usefixtures(
    "setup_mero_locker",
    "setup_address_provider",
)
def test_burn_fees_eth_no_pool(rewardHandler, mockFeeBurner, alice, meroLocker, admin):
    alice.transfer(rewardHandler, 1e18)

    assert mockFeeBurner.balance() == 0
    tx = rewardHandler.burnFees({"from": alice})
    assert mockFeeBurner.balance() == 0


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider", "setup_eth_pool")
def test_burn_fees_eth(rewardHandler, mockFeeBurner, alice, meroLocker, admin):
    alice.transfer(rewardHandler, 1e18)

    assert mockFeeBurner.balance() == 0
    tx = rewardHandler.burnFees({"from": alice})
    assert mockFeeBurner.balance() == 1e18
    assert tx.events["FeesDeposited"][0]["amount"] == 1e18
    assert tx.events["Burned"][0]["rewardToken"] == meroLocker.rewardToken()
    assert tx.events["Burned"][0]["totalAmount"] == 1e18


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider", "setup_vault")
def test_burn_fees_after_harvest(
    rewardHandler, mockFeeBurner, coin, decimals, vault, alice, admin
):
    strategy = vault.strategy()
    amount = 100_000 * 10**decimals
    coin.mint_for_testing(strategy, amount, {"from": admin})

    vault.harvest({"from": admin})
    rewardHandler.burnFees({"from": alice})

    assert coin.balanceOf(rewardHandler) == 0
    assert pytest.approx(coin.balanceOf(mockFeeBurner)) == amount * 0.05 * 0.89


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider", "setup_vault")
def test_burn_fees_multiple_vaults(
    vault2, coin2, rewardHandler, mockFeeBurner, coin, decimals, vault, alice, admin
):
    strategy = vault.strategy()
    strategy2 = vault2.strategy()

    amount = 100_000 * 10**decimals
    amount2 = 100_000 * 10**6

    coin.mint_for_testing(strategy, amount, {"from": admin})
    coin2.mint_for_testing(strategy2, amount2, {"from": admin})

    vault.harvest({"from": admin})
    vault2.harvest({"from": admin})

    rewardHandler.burnFees({"from": alice})

    assert coin.balanceOf(rewardHandler) == 0
    assert coin2.balanceOf(rewardHandler) == 0

    assert pytest.approx(coin.balanceOf(mockFeeBurner)) == amount * 0.05 * 0.89
    assert coin2.balanceOf(mockFeeBurner) == amount2 * 0.5
