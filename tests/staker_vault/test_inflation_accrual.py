import pytest
from support.constants import Roles
from support.contract_utils import update_topup_handler
from support.types import TopUpRecord
from support.utils import encode_account, scale
from brownie import reverts

PROTOCOL_1_ADDRESS = "0x3d9819210a31b4961b30ef54be2aed79b9c9cd3b"

pytestmark = pytest.mark.usefixtures("setup_staker_vault_and_minter", "registerSetUp")

ADMIN_DELAY = 5 * 86400


@pytest.fixture
def registerSetUp(topUpAction, address_provider, admin, pool, mockTopUpHandler):
    address_provider.addPool(pool, {"from": admin})
    update_topup_handler(topUpAction, PROTOCOL_1_ADDRESS, mockTopUpHandler, admin)


@pytest.fixture
def setup_staker_vault_and_minter(
    address_provider,
    inflation_manager,
    admin,
    stakerVault,
    lpToken,
    mockKeeperGauge,
    topUpAction,
    minter,
    pool,
    lpGauge,
):
    inflation_manager.setMinter(minter, {"from": admin})
    inflation_manager.setKeeperGauge(pool, mockKeeperGauge, {"from": admin})
    address_provider.addPool(pool, {"from": admin})

    inflation_manager.updateKeeperPoolWeight(pool, scale("0.5"), {"from": admin})
    inflation_manager.updateLpPoolWeight(lpToken, scale("0.5"), {"from": admin})
    address_provider.addAction(topUpAction, {"from": admin})


def test_staking_correctly_updates_balances(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    meroToken,
    lpGauge,
    admin,
):

    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserShare(bob) == 0

    TEST_DELAY = 2 * 86400

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time
    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})
    firstUpdateTimestamp = lpGauge.poolLastUpdate()

    chain.sleep(TEST_DELAY)
    chain.mine()

    assert stakerVault.getPoolTotalStaked() == 2e18
    # Bob stakes
    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 3e18, {"from": bob})
    stakerVault.stake(3e18, {"from": bob})

    secondDepostiTimestamp = chain[-1]["timestamp"]

    totalStakedIntegralShouldFirstStakes = (
        (secondDepostiTimestamp - firstUpdateTimestamp) * poolLpRate / 2
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18)
        == totalStakedIntegralShouldFirstStakes
    )
    assert stakerVault.getPoolTotalStaked() == 5e18

    # Alice increases her stake
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})

    lastUpdateTimestamp = chain[-1]["timestamp"]
    totalStakedIntegralShouldSecondStakes = totalStakedIntegralShouldFirstStakes + (
        (lastUpdateTimestamp - secondDepostiTimestamp) * poolLpRate / 5e18
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18)
        == totalStakedIntegralShouldSecondStakes
    )

    assert stakerVault.getPoolTotalStaked() == 7e18
    assert lpGauge.poolLastUpdate() == lastUpdateTimestamp
    assert (
        pytest.approx(lpGauge.perUserStakedIntegral(bob), abs=3e18)
        == totalStakedIntegralShouldFirstStakes
    )
    assert (
        pytest.approx(lpGauge.perUserStakedIntegral(alice), abs=3e18)
        == totalStakedIntegralShouldSecondStakes
    )


def test_inflation_accrual_single_staking(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    minter,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time

    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})
    firstUpdateTimestamp = lpGauge.poolLastUpdate()
    firstDepositTimeStamp = chain[-1]["timestamp"]

    assert stakerVault.getPoolTotalStaked() == 2e18

    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    secondDepositTimestamp = chain[-1]["timestamp"]
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 6e18

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()

    # With pool weight 0.5 from the setup fixture
    totalPoolStakedIntegral = (
        (chain[-1]["timestamp"] - firstUpdateTimestamp) * poolLpRate / 6
    )

    lpGauge.poolCheckpoint()

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_rewards_should = (
        (chain[-1]["timestamp"] - firstDepositTimeStamp) * poolLpRate * 4 / 6
    )
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=5e18) == bob_rewards_should

    alice_reward_should = (
        (chain[-1]["timestamp"] - secondDepositTimestamp) * poolLpRate * 2 / 6
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=10e18) == alice_reward_should


def test_inflation_accrual_with_killed_gauge(
    stakerVault,
    alice,
    bob,
    lpToken,
    chain,
    inflation_manager,
    lpGauge,
    admin,
    LpGauge,
    address_provider,
    meroToken,
):
    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    # ALice stakes first time

    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})
    firstDepositTimeStamp = chain[-1]["timestamp"]

    assert stakerVault.getPoolTotalStaked() == 2e18

    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 6e18

    new_lp_gauge = admin.deploy(LpGauge, address_provider, stakerVault)

    TEST_DELAY = 7 * 86400
    chain.sleep(TEST_DELAY)
    chain.mine()

    tx = stakerVault.updateLpGauge(new_lp_gauge, {"from": admin})

    assert lpGauge.killed()

    chain.sleep(TEST_DELAY)
    chain.mine()

    bob_rewards_should = (tx.timestamp - firstDepositTimeStamp) * poolLpRate * 4 / 6
    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=5e18) == bob_rewards_should

    chain.sleep(TEST_DELAY)
    chain.mine()

    assert lpGauge.claimableRewards(bob) == 0

    tx = lpGauge.claimRewards(bob, {"from": bob})
    assert tx.return_value == 0


def test_inflation_accrual_twice_staking(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time
    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})
    firstUpdateTimestamp = lpGauge.poolLastUpdate()
    firstDepositTimeStamp = chain[-1]["timestamp"]

    assert stakerVault.getPoolTotalStaked() == 2e18
    assert lpGauge.poolStakedIntegral() == 0

    # Bob stakes first time
    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    secondDepositTimestamp = chain[-1]["timestamp"]
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 6e18
    totalPoolStakedIntegral = (
        (secondDepositTimestamp - firstUpdateTimestamp) * poolLpRate / 2
    )
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    TEST_DELAY = 4 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()

    # Alice stakes second time
    thirdDepositTimestamp = chain[-1]["timestamp"]
    lpToken.approve(stakerVault, 1e18, {"from": alice})
    stakerVault.stake(1e18, {"from": alice})

    assert stakerVault.getPoolTotalStaked() == 7e18
    totalPoolStakedIntegral += (
        (thirdDepositTimestamp - secondDepositTimestamp) * poolLpRate / 6
    )
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    chain.sleep(TEST_DELAY)
    chain.mine()

    alice_reward_should = (
        (secondDepositTimestamp - firstUpdateTimestamp) * poolLpRate
        + (thirdDepositTimestamp - secondDepositTimestamp) * poolLpRate * 2 / 6
        + (chain[-1]["timestamp"] - thirdDepositTimestamp) * poolLpRate * 3 / 7
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=20e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=20e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=20e18) == alice_reward_should

    totalPoolStakedIntegral += (
        (chain[-1]["timestamp"] - thirdDepositTimestamp) * poolLpRate / 7
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=10e18)
        == totalPoolStakedIntegral
    )

    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_reward_should = (
        thirdDepositTimestamp - secondDepositTimestamp
    ) * poolLpRate * 4 / 6 + (
        chain[-1]["timestamp"] - thirdDepositTimestamp
    ) * poolLpRate * 4 / 7
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == bob_reward_should
    )
    assert pytest.approx(predicted_bob, abs=20e18) == bob_reward_should

    totalPoolStakedIntegral = (
        thirdDepositTimestamp - firstUpdateTimestamp
    ) * poolLpRate / 6 + (
        chain[-1]["timestamp"] - thirdDepositTimestamp
    ) * poolLpRate / 7

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=10e18)
        == totalPoolStakedIntegral
    )


def test_inflation_accrual_single_deposit_to_action(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    topUpAction,
    coin,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time
    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    assert lpToken.balanceOf(alice) == 4e18
    lpToken.approve(topUpAction, 2e18, {"from": alice})
    # stakerVault.stake(2e18, {"from": alice})

    topUpAction.register(
        encode_account(bob),
        PROTOCOL_1_ADDRESS,
        scale(2),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(2),
            totalTopUpAmount=scale(2),
        ),
        {"from": alice, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )

    firstDepositTimeStamp = chain[-1]["timestamp"]
    firstUpdateTimestamp = lpGauge.poolLastUpdate()
    assert stakerVault.getPoolTotalStaked() == 2e18
    # With pool weight 0.5 from the setup fixture

    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    secondDepositTimestamp = chain[-1]["timestamp"]
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 6e18
    totalPoolStakedIntegral = (
        (chain[-1]["timestamp"] - firstUpdateTimestamp) * poolLpRate / 2
    )
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()
    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_rewards_should = (
        (chain[-1]["timestamp"] - firstDepositTimeStamp) * poolLpRate * 4 / 6
    )
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=10e18) == bob_rewards_should

    alice_reward_should = (
        (chain[-1]["timestamp"] - secondDepositTimestamp) * poolLpRate * 2 / 6
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=20e18) == alice_reward_should


def test_inflation_accrual_both_deposit_to_action(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    topUpAction,
    coin,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time

    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(topUpAction, 2e18, {"from": alice})

    topUpAction.register(
        encode_account(bob),
        PROTOCOL_1_ADDRESS,
        scale(2),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(2),
            totalTopUpAmount=scale(2),
        ),
        {"from": alice, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )
    firstDepositTimeStamp = chain[-1]["timestamp"]
    firstUpdateTimestamp = lpGauge.poolLastUpdate()
    assert stakerVault.getPoolTotalStaked() == 2e18

    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(topUpAction, 4e18, {"from": bob})

    secondDepositTimestamp = chain[-1]["timestamp"]
    topUpAction.register(
        encode_account(alice),
        PROTOCOL_1_ADDRESS,
        scale(4),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(4),
            totalTopUpAmount=scale(4),
        ),
        {"from": bob, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )

    assert stakerVault.getPoolTotalStaked() == 6e18

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)

    # With pool weight 0.5 from the setup fixture
    totalPoolStakedIntegral = (
        (chain[-1]["timestamp"] - firstUpdateTimestamp) * poolLpRate / 6
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )
    chain.mine()
    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_rewards_should = (
        (chain[-1]["timestamp"] - firstDepositTimeStamp) * poolLpRate * 4 / 6
    )
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=3e18) == bob_rewards_should

    alice_reward_should = (
        (chain[-1]["timestamp"] - secondDepositTimestamp) * poolLpRate * 2 / 6
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=10e18) == alice_reward_should


def test_inflation_accrual_staking_and_action_registration(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    topUpAction,
    coin,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time
    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(topUpAction, 2e18, {"from": alice})

    topUpAction.register(
        encode_account(bob),
        PROTOCOL_1_ADDRESS,
        scale(2),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(2),
            totalTopUpAmount=scale(2),
        ),
        {"from": alice, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )

    firstDepositTimeStamp = chain[-1]["timestamp"]
    firstUpdateTimestamp = lpGauge.poolLastUpdate()
    assert stakerVault.getPoolTotalStaked() == 2e18

    # Bob stakes first time
    secondDepositTimestamp = chain[-1]["timestamp"]
    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(topUpAction, 4e18, {"from": bob})

    topUpAction.register(
        encode_account(alice),
        PROTOCOL_1_ADDRESS,
        scale(4),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(4),
            totalTopUpAmount=scale(4),
        ),
        {"from": bob, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )

    assert stakerVault.getPoolTotalStaked() == 6e18
    totalPoolStakedIntegral = (
        (secondDepositTimestamp - firstUpdateTimestamp) * poolLpRate / 2
    )
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    TEST_DELAY = 4 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()

    # Alice stakes second time
    thirdDepositTimestamp = chain[-1]["timestamp"]
    lpToken.approve(stakerVault, 1e18, {"from": alice})
    stakerVault.stake(1e18, {"from": alice})

    assert stakerVault.getPoolTotalStaked() == 7e18
    totalPoolStakedIntegral += (
        (thirdDepositTimestamp - secondDepositTimestamp) * poolLpRate / 6
    )
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    chain.sleep(TEST_DELAY)
    chain.mine()

    alice_reward_should = (
        (secondDepositTimestamp - firstUpdateTimestamp) * poolLpRate
        + (thirdDepositTimestamp - secondDepositTimestamp) * poolLpRate * 2 / 6
        + (chain[-1]["timestamp"] - thirdDepositTimestamp) * poolLpRate * 3 / 7
    )

    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=3e18) == alice_reward_should

    totalPoolStakedIntegral += (
        (chain[-1]["timestamp"] - thirdDepositTimestamp) * poolLpRate / 7
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_reward_should = (
        thirdDepositTimestamp - secondDepositTimestamp
    ) * poolLpRate * 4 / 6 + (
        chain[-1]["timestamp"] - thirdDepositTimestamp
    ) * poolLpRate * 4 / 7
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_reward_should
    )
    assert pytest.approx(predicted_bob, abs=3e18) == bob_reward_should

    totalPoolStakedIntegral = (
        thirdDepositTimestamp - firstUpdateTimestamp
    ) * poolLpRate / 6 + (
        chain[-1]["timestamp"] - thirdDepositTimestamp
    ) * poolLpRate / 7

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )


def test_inflation_accrual_single_deposit_to_action_with_removal(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    topUpAction,
    coin,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time

    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    assert lpToken.balanceOf(alice) == 4e18
    lpToken.approve(topUpAction, 2e18, {"from": alice})
    # stakerVault.stake(2e18, {"from": alice})

    topUpAction.register(
        encode_account(bob),
        PROTOCOL_1_ADDRESS,
        scale(2),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(2),
            totalTopUpAmount=scale(2),
        ),
        {"from": alice, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )
    firstDepositTimeStamp = chain[-1]["timestamp"]
    firstUpdateTimestamp = lpGauge.poolLastUpdate()

    assert stakerVault.getPoolTotalStaked() == 2e18

    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    secondDepositTimestamp = chain[-1]["timestamp"]
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 6e18

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)

    # With pool weight 0.5 from the setup fixture
    totalPoolStakedIntegral = (
        (chain[-1]["timestamp"] - firstUpdateTimestamp) * poolLpRate / 6
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    topUpAction.resetPosition(
        encode_account(bob), PROTOCOL_1_ADDRESS, False, {"from": alice}
    )
    chain.sleep(TEST_DELAY)
    chain.mine()

    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_rewards_should = (
        (chain[-1]["timestamp"] - firstDepositTimeStamp) * poolLpRate * 4 / 6
    )
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=3e18) == bob_rewards_should

    alice_reward_should = (
        (chain[-1]["timestamp"] - secondDepositTimestamp) * poolLpRate * 2 / 6
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=10e18) == alice_reward_should


def test_actions_do_not_accrue_inflation(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    topUpAction,
    coin,
    meroToken,
    lpGauge,
    admin,
    role_manager,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    assert lpToken.balanceOf(alice) == 4e18
    lpToken.approve(topUpAction, 2e18, {"from": alice})

    topUpAction.register(
        encode_account(bob),
        PROTOCOL_1_ADDRESS,
        scale(2),
        TopUpRecord(
            threshold=scale("5"),
            priorityFee=scale(1, 9),
            maxFee=scale(5, 9),
            actionToken=coin,
            depositToken=lpToken,
            singleTopUpAmount=scale(2),
            totalTopUpAmount=scale(2),
        ),
        {"from": alice, "value": scale(5, 9) * topUpAction.estimatedGasUsage()},
    )

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()

    topUpAction.resetPosition(
        encode_account(bob), PROTOCOL_1_ADDRESS, False, {"from": alice}
    )
    role_manager.addGaugeZap(admin, {"from": admin})
    tx = lpGauge.claimRewards(topUpAction, {"from": admin})


def test_inflation_accrual_single_staking_large_amounts(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    minter,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0
    assert lpGauge.perUserStakedIntegral(bob) == 0
    assert lpGauge.perUserShare(bob) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0
    print(poolLpRate)

    # ALice stakes first time

    lpToken.mint_for_testing(alice, 400_000_000e18, {"from": admin})
    lpToken.approve(stakerVault, 400_000_000e18, {"from": alice})
    stakerVault.stake(400_000_000e18, {"from": alice})
    firstDepositTimeStamp = chain[-1]["timestamp"]
    firstUpdateTimestamp = lpGauge.poolLastUpdate()

    assert stakerVault.getPoolTotalStaked() == 400_000_000e18

    secondDepositTimestamp = chain[-1]["timestamp"]
    lpToken.mint_for_testing(bob, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 4e18, {"from": bob})
    stakerVault.stake(4e18, {"from": bob})

    assert stakerVault.getPoolTotalStaked() == 400_000_004e18

    TEST_DELAY = 7 * 86400

    chain.sleep(TEST_DELAY)
    chain.mine()

    # With pool weight 0.5 from the setup fixture

    lpGauge.poolCheckpoint()
    totalPoolStakedIntegral = (
        (chain[-1]["timestamp"] - firstUpdateTimestamp) * poolLpRate / 400_000_004
    )

    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    predicted_bob = lpGauge.claimableRewards(bob)
    tx = lpGauge.claimRewards(bob, {"from": bob})
    bob_rewards_should = (
        (chain[-1]["timestamp"] - secondDepositTimestamp) * poolLpRate * 4 / 400_000_004
    )
    assert tx.events["TokensMinted"][0]["beneficiary"] == bob
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == bob_rewards_should
    )
    assert pytest.approx(predicted_bob, abs=3e18) == bob_rewards_should

    alice_reward_should = (
        (chain[-1]["timestamp"] - firstDepositTimeStamp)
        * poolLpRate
        * 400_000_000
        / 400_000_004
    )
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=20e18) == alice_reward_should


def test_set_zap(
    lpGauge, alice, bob, chain, admin, charlie, lpToken, stakerVault, role_manager
):
    # Should be null by default
    assert role_manager.getRoleMemberCount(Roles.GAUGE_ZAP.value) == 0

    # Generating rewards
    lpToken.mint_for_testing(alice, 4e18, {"from": admin})
    lpToken.approve(stakerVault, 2e18, {"from": alice})
    stakerVault.stake(2e18, {"from": alice})
    chain.sleep(7 * 86400)
    chain.mine()

    # Should revert from non owner
    with reverts("unauthorized access"):
        lpGauge.claimRewards(alice, {"from": bob})

    # Should revert setting zap from non-admin
    with reverts("unauthorized access"):
        role_manager.addGaugeZap(charlie, {"from": bob})

    # Should set zap
    role_manager.addGaugeZap(charlie, {"from": admin})
    assert role_manager.getRoleMember(Roles.GAUGE_ZAP.value, 0) == charlie

    # Should be able to claim on behalf of zap
    lpGauge.claimRewards(alice, {"from": charlie})


def test_inflation_accrual_single_staking_inflation_decay_period_passes(
    stakerVault,
    alice,
    bob,
    pool,
    lpToken,
    chain,
    inflation_manager,
    minter,
    meroToken,
    lpGauge,
    admin,
):
    assert lpGauge.poolStakedIntegral() == 0
    assert lpGauge.perUserStakedIntegral(alice) == 0
    assert lpGauge.perUserShare(alice) == 0

    poolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    assert poolLpRate > 0

    # ALice stakes first time
    lpToken.mint_for_testing(alice, 6e18, {"from": admin})
    lpToken.approve(stakerVault, 6e18, {"from": alice})
    stakerVault.stake(6e18, {"from": alice})
    firstDepositTimeStamp = chain[-1]["timestamp"]

    assert stakerVault.getPoolTotalStaked() == 6e18
    TEST_DELAY = 380 * 86400
    chain.sleep(TEST_DELAY)
    chain.mine()

    lastDecayTime = minter.lastInflationDecay()

    # This triggers the inflation rate update
    tx = lpGauge.poolCheckpoint()
    assert len(tx.events["InflationRateUpdated"]) == 1

    decayTime = lastDecayTime + 365 * 86400
    endTime = chain[-1]["timestamp"]
    newPoolLpRate = inflation_manager.getLpRateForStakerVault(stakerVault)
    # With pool weight 0.5 from the setup fixture
    totalPoolStakedIntegral = (decayTime - firstDepositTimeStamp) * poolLpRate / 6 + (
        endTime - decayTime
    ) * newPoolLpRate / 6
    assert (
        pytest.approx(lpGauge.poolStakedIntegral(), abs=3e18) == totalPoolStakedIntegral
    )

    alice_reward_should = (decayTime - firstDepositTimeStamp) * poolLpRate + (
        endTime - decayTime
    ) * newPoolLpRate
    predicted_alice = lpGauge.claimableRewards(alice)
    tx = lpGauge.claimRewards(alice, {"from": alice})
    assert tx.events["TokensMinted"][0]["beneficiary"] == alice
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=3e18)
        == tx.return_value
    )
    assert (
        pytest.approx(tx.events["TokensMinted"][0]["amount"], abs=10e18)
        == alice_reward_should
    )
    assert pytest.approx(predicted_alice, abs=10e18) == alice_reward_should
