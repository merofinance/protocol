import brownie
from brownie import ZERO_ADDRESS
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
    address_provider.initializeAddress(format_to_bytes("rewardHandler", 32), rewardHandler, {"from": admin})


@pytest.fixture(scope="module")
def some_pool(MockErc20, MockErc20Pool, admin, controller, LpToken):
    coin = admin.deploy(MockErc20, 18)
    pool = admin.deploy(MockErc20Pool, controller)
    lp_token = admin.deploy(LpToken)
    pool.initialize("some-pool", coin, ZERO_ADDRESS, scale("0.03"), 0)
    lp_token.initialize("Some LP", "SLP", 18, pool)
    pool.setLpToken(lp_token, {"from": admin})
    return pool


@pytest.fixture(scope="module")
def set_vault(some_pool, admin, Erc20Vault, controller, vaultReserve, address_provider):
    vault = admin.deploy(Erc20Vault, controller)
    vault.initialize(some_pool, 0, 0, 0, {"from": admin})
    some_pool.setVault(vault, False, {"from": admin})


def test_add_pool(some_pool, admin, alice, address_provider):
    with brownie.reverts("unauthorized access"):
        address_provider.addPool(some_pool, {"from": alice})

    tx = address_provider.addPool(some_pool, {"from": admin})
    assert len(tx.events) == 1
    assert tx.events[0]["pool"] == some_pool
    assert address_provider.allPools() == [some_pool]
    assert address_provider.getPoolForToken(some_pool.lpToken()) == some_pool
    assert len(address_provider.allVaults()) == 0


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider", "set_vault")
def test_add_pool_with_vault(some_pool, admin, alice, address_provider):
    poolCount = len(address_provider.allPools())
    with brownie.reverts("unauthorized access"):
        address_provider.addPool(some_pool, {"from": alice})

    tx = address_provider.addPool(some_pool, {"from": admin})
    assert len(tx.events) == 1
    assert tx.events[0]["pool"] == some_pool
    assert len(address_provider.allPools()) == poolCount + 1
    assert address_provider.getPoolForToken(some_pool.lpToken()) == some_pool
    assert address_provider.allVaults() == [some_pool.vault()]


def test_add_existing_pool(some_pool, admin, address_provider):
    poolCount = len(address_provider.allPools())
    address_provider.addPool(some_pool, {"from": admin})
    tx = address_provider.addPool(some_pool, {"from": admin})
    assert len(tx.events) == 0
    assert len(address_provider.allPools()) == poolCount + 1


def remove_existing_pool(
    EthPool, EthVault, LpToken, some_pool, admin, alice, controller, address_provider
):
    otherPool = admin.deploy(EthPool, controller)
    otherLpToken = admin.deploy(LpToken)
    otherPool.initialize("eth-pool", ZERO_ADDRESS, scale("0.03"), 0)
    otherLpToken.initialize("Other LP", "OLP", 18, otherPool)
    otherPool.setLpToken(otherLpToken, {"from": admin})
    otherVault = admin.deploy(EthVault, controller)
    otherVault.initialize(otherPool, 0, 0, 0, {"from": admin})
    otherPool.setVault(otherVault, False, {"from": admin})

    address_provider.addPool(some_pool, {"from": admin})
    address_provider.addPool(otherPool, {"from": admin})

    poolCount = len(address_provider.allPools())
    assert set(address_provider.allVaults()) == set(
        [some_pool.vault(), otherPool.vault()]
    )
    with brownie.reverts("unauthorized access"):
        controller.shutdownPool(some_pool, True, {"from": alice})

    tx = controller.shutdownPool(some_pool, True, {"from": admin})
    assert len(tx.events["Shutdown"]) == 1
    assert len(address_provider.allPools()) == poolCount
    assert some_pool.isShutdown()

    controller.shutdownPool(otherPool, True, {"from": admin})
    assert len(address_provider.allPools()) == poolCount
    assert otherPool.isShutdown()


@pytest.mark.usefixtures("setup_mero_locker", "setup_address_provider", "set_vault")
def test_remove_existing_pool(
    MockEthPool,
    EthVault,
    LpToken,
    some_pool,
    admin,
    alice,
    controller,
    address_provider,
):
    remove_existing_pool(
        MockEthPool,
        EthVault,
        LpToken,
        some_pool,
        admin,
        alice,
        controller,
        address_provider,
    )


@pytest.mark.usefixtures(
    "setup_mero_locker", "setup_address_provider", "inflation_kickoff"
)
def test_remove_existing_pool_with_inflation(
    MockEthPool,
    EthVault,
    LpToken,
    pool_with_vault,
    admin,
    alice,
    controller,
    address_provider,
    inflation_manager,
    stakerVault,
):
    assert inflation_manager.getLpRateForStakerVault(stakerVault) != 0
    remove_existing_pool(
        MockEthPool,
        EthVault,
        LpToken,
        pool_with_vault,
        admin,
        alice,
        controller,
        address_provider,
    )
    assert inflation_manager.getLpRateForStakerVault(stakerVault) == 0
