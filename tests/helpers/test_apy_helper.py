import pytest

from support.utils import scale
from support.mainnet_contracts import TokenAddresses


CONVEX_PID = 40
CURVE_POOL = "0x5a6A4D54456819380173272A5E8E9B9904BdF41B"
CURVE_HOP_POOL = "0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7"
CURVE_INDEX_USDC = 1
CURVE_INDEX_DAI = 0
TARGET_ALLOC = 1


@pytest.fixture(scope="module")
@pytest.mark.mainnetFork
def strategy(MeroTriHopCvx, admin, alice, address_provider, coin, vault):
    return admin.deploy(
        MeroTriHopCvx,
        vault,
        alice,
        CONVEX_PID,
        CURVE_POOL,
        1,
        CURVE_HOP_POOL,
        CURVE_INDEX_DAI if coin.address == TokenAddresses.DAI else CURVE_INDEX_USDC,
        address_provider
    )


@pytest.fixture
def setUp(admin, vault, strategy):
    vault.setStrategy(strategy, {"from": admin})
    vault.activateStrategy({"from": admin})
    vault.setTargetAllocation(scale(TARGET_ALLOC))


@pytest.mark.usefixtures("setUp")
@pytest.mark.mainnetFork
def test_set_up(vault, strategy, pool, coin):
    assert vault.pool() == pool
    assert pool.vault() == vault
    assert vault.strategy() == strategy
    assert pool.getUnderlying() == coin


def test_is_one_for_new_pool(pool, apyHelper, decimals):
    assert apyHelper.exchangeRateIncludingHarvestable(pool) == scale(1, decimals)


@pytest.mark.usefixtures("setUp")
@pytest.mark.mainnetFork
def test_exchange_rate_after_deposit(coin, decimals, pool, apyHelper, alice):
    DEPOSIT = scale(10, decimals)
    coin.approve(pool, 2**256 - 1, {"from": alice})
    pool.deposit(DEPOSIT, {"from": alice})
    assert pool.exchangeRate() == scale(1, decimals)
    assert apyHelper.exchangeRateIncludingHarvestable(pool) == scale(1, decimals)


@pytest.mark.usefixtures("setUp")
@pytest.mark.mainnetFork
def test_exchange_rate_after_profiting(decimals, coin, pool, alice, apyHelper):
    DEPOSIT = scale(10, decimals)
    coin.approve(pool, 2**256 - 1, {"from": alice})
    pool.deposit(DEPOSIT, {"from": alice})
    coin.transfer(apyHelper, DEPOSIT, {"from": alice})
    assert pool.exchangeRate() > 0
    assert pytest.approx(apyHelper.exchangeRateIncludingHarvestable(pool)) == pool.exchangeRate()


@pytest.mark.usefixtures("setUp")
@pytest.mark.mainnetFork
def test_exchange_rate_with_harvestable(pool, apyHelper, coin, alice, decimals, MeroTriHopCvx, bob, address_provider, admin, chain):
    DEPOSIT = scale(10, decimals)
    coin.approve(pool, 2**256 - 1, {"from": alice})
    pool.deposit(DEPOSIT, {"from": alice})
    coin.transfer(apyHelper, DEPOSIT, {"from": alice})
    second_strategy = admin.deploy(
        MeroTriHopCvx,
        bob,
        alice,
        CONVEX_PID,
        CURVE_POOL,
        1,
        CURVE_HOP_POOL,
        CURVE_INDEX_DAI if coin.address == TokenAddresses.DAI else CURVE_INDEX_USDC,
        address_provider
    )
    second_strategy.setImbalanceToleranceOut(scale("0.3"), {"from": admin})
    coin.transfer(second_strategy, scale(10, decimals), {"from": admin})
    second_strategy.deposit({"from": bob, "value": 0})
    second_strategy.withdraw(scale(5, decimals), {"from": bob})
    chain.sleep(3 * 86400)
    second_strategy.harvest({"from": bob})
    assert apyHelper.exchangeRateIncludingHarvestable(pool) > pool.exchangeRate()
    assert apyHelper.exchangeRateIncludingHarvestable(pool) < pool.exchangeRate() * 2


def test_exchange_rates(address_provider, apyHelper, pool):
    pools = address_provider.allPools()
    assert len(pools) > 0
    exchangeRates = apyHelper.exchangeRatesIncludingHarvestable()
    assert len(exchangeRates) == len(pools)
    assert exchangeRates[0][0] == pools[0]
    assert exchangeRates[0][1] == scale(1, 18)
