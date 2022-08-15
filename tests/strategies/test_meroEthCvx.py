import pytest
from brownie import reverts  # type: ignore
from support.utils import get_first_event, scale
from support.mainnet_contracts import TokenAddresses, VendorAddresses

# alETH (Factory Pool)
curve_pool_address = VendorAddresses.CURVE_ALETH_ETH_POOL
convex_pid = 49
curve_index = 0


@pytest.fixture(scope="session")
def strategy_vault(accounts):
    return accounts[8]


@pytest.fixture
@pytest.mark.mainnetFork
def strategy(MeroEthCvx, strategy_vault, admin, alice, address_provider):
    return admin.deploy(
        MeroEthCvx,
        strategy_vault,
        alice,
        convex_pid,
        curve_pool_address,
        curve_index,
        address_provider,
    )


# Requires
@pytest.mark.mainnetFork
def test_revert_on_deposit_from_non_admin(strategy, alice):
    with reverts("unauthorized access"):
        strategy.deposit({"from": alice, "value": 1})


@pytest.mark.mainnetFork
def test_revert_on_deposit_when_shut_down(strategy, strategy_vault):
    tx = strategy.shutdown({"from": strategy_vault})
    assert len(tx.events) == 1
    with reverts("Strategy is shutdown"):
        strategy.deposit({"from": strategy_vault, "value": 0})


@pytest.mark.mainnetFork
def test_revert_on_harvest_from_non_vault(strategy, admin):
    with reverts("unauthorized access"):
        strategy.harvest({"from": admin})


@pytest.mark.mainnetFork
def test_revert_on_withdraw_from_non_vault(strategy, admin):
    with reverts("unauthorized access"):
        strategy.withdraw(1, {"from": admin})


@pytest.mark.mainnetFork
def test_revert_on_withdraw_for_insufficient_balance(strategy, strategy_vault):
    with reverts():
        strategy.withdraw(1, {"from": strategy_vault})


@pytest.mark.mainnetFork
def test_revert_on_withdraw_all_from_non_admin(strategy, alice):
    with reverts("unauthorized access"):
        strategy.withdrawAll({"from": alice})


@pytest.mark.mainnetFork
def test_revert_on_add_reward_token_from_non_admin(strategy, alice, sushi):
    with reverts("unauthorized access"):
        strategy.addRewardToken(sushi, {"from": alice})


@pytest.mark.mainnetFork
def test_revert_on_add_reward_token_as_crv(strategy, admin, crv):
    with reverts("Invalid token to add"):
        strategy.addRewardToken(crv, {"from": admin})


@pytest.mark.mainnetFork
def test_revert_on_add_reward_token_as_cvx(strategy, admin, cvx):
    with reverts("Invalid token to add"):
        strategy.addRewardToken(cvx, {"from": admin})


@pytest.mark.mainnetFork
def test_revert_on_removing_reward_token_from_non_admin(strategy, alice, sushi):
    with reverts("unauthorized access"):
        strategy.removeRewardToken(sushi, {"from": alice})


# Functions
@pytest.mark.mainnetFork
def test_deposit_starts_with_no_balance(strategy):
    assert strategy.balance() == 0


@pytest.mark.mainnetFork
def test_deposit_returns_false_with_no_balance(strategy, strategy_vault):
    tx = strategy.deposit({"from": strategy_vault, "value": 0})
    assert tx.return_value == False


@pytest.mark.mainnetFork
def test_deposit(strategy, strategy_vault, decimals, interface):
    tx = strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    assert strategy.balance() > scale(9, decimals)
    assert strategy.balance() < scale(11, decimals)
    crvRewards = interface.IRewardStaking(strategy.rewards())
    assert crvRewards.balanceOf(strategy) > scale(9, decimals)


@pytest.mark.mainnetFork
def test_deposit_fails_when_curve_imbalanced(
    strategy, strategy_vault, admin, decimals, interface
):
    # Imbalancing pool
    amount = admin.balance() - scale(100)
    otherIndex = 1 if curve_index == 0 else 0
    curvePool = interface.ICurveSwap(curve_pool_address)
    curvePool.exchange(
        curve_index, otherIndex, amount, 0, {"from": admin, "value": amount}
    )

    # Depositing
    with reverts():
        strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})


@pytest.mark.mainnetFork
def test_withdraw_with_0_amount(strategy, strategy_vault):
    tx = strategy.withdraw(0, {"from": strategy_vault})
    assert tx.return_value == False


@pytest.mark.mainnetFork
def test_withdraw_with_idle_balance(strategy, strategy_vault, decimals):
    strategy_vault.transfer(strategy, scale(10, decimals))
    vault_balance_before = strategy_vault.balance()
    tx = strategy.withdraw(scale(5, decimals), {"from": strategy_vault})
    vault_balance_after = strategy_vault.balance()
    wei_used_for_gas = tx.gas_used * tx.gas_price
    assert tx.events["Withdraw"]["amount"] == scale(5, decimals)
    assert tx.return_value == True
    assert vault_balance_after - vault_balance_before + wei_used_for_gas == scale(
        5, decimals
    )
    assert strategy.balance() < scale(6, decimals)
    assert strategy.balance() > scale(4, decimals)


@pytest.mark.mainnetFork
def test_withdraw_with_all_deposited(strategy, strategy_vault, decimals, interface):
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    vault_balance_before = strategy_vault.balance()
    tx = strategy.withdraw(scale(5, decimals), {"from": strategy_vault})
    vault_balance_after = strategy_vault.balance()
    wei_used_for_gas = tx.gas_used * tx.gas_price
    assert tx.return_value == True
    assert get_first_event(tx, "Withdraw")["amount"] == scale(5, decimals)
    assert vault_balance_after - vault_balance_before + wei_used_for_gas == scale(
        5, decimals
    )
    crvRewards = interface.IRewardStaking(strategy.rewards())
    depositedBalance = crvRewards.balanceOf(strategy)
    assert depositedBalance < scale(6, decimals)
    assert depositedBalance > scale(4, decimals)


@pytest.mark.mainnetFork
def test_withdraw_with_some_deposited(strategy, strategy_vault, decimals, interface):
    strategy.deposit({"from": strategy_vault, "value": scale(4, decimals)})
    strategy_vault.transfer(strategy, scale(4, decimals))
    vault_balance_before = strategy_vault.balance()
    tx = strategy.withdraw(scale(5, decimals), {"from": strategy_vault})
    vault_balance_after = strategy_vault.balance()
    wei_used_for_gas = tx.gas_used * tx.gas_price
    assert tx.return_value == True
    assert vault_balance_after - vault_balance_before + wei_used_for_gas == scale(
        5, decimals
    )
    crvRewards = interface.IRewardStaking(strategy.rewards())
    depositedBalance = crvRewards.balanceOf(strategy)
    assert depositedBalance < scale(4, decimals)
    assert depositedBalance > scale(2, decimals)


@pytest.mark.mainnetFork
def test_withdraw_fails_when_curve_imbalanced(
    strategy, admin, strategy_vault, decimals
):
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    strategy.setImbalanceToleranceOut(0, {"from": admin})
    with reverts():
        strategy.withdraw(scale(8000, decimals), {"from": strategy_vault})


@pytest.mark.mainnetFork
def test_withdraw_all_with_idle_balance(strategy, strategy_vault, decimals):
    strategy_vault.transfer(strategy, scale(10, decimals))
    vaultBalanceBefore = strategy_vault.balance()
    tx = strategy.withdrawAll({"from": strategy_vault})
    assert tx.return_value > scale(9, decimals)
    assert strategy_vault.balance() - vaultBalanceBefore > scale(9, decimals)
    assert strategy.balance() == 0


@pytest.mark.mainnetFork
def test_withdraw_all_with_all_deposited(strategy, strategy_vault, decimals, interface):
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    vault_balance_before = strategy_vault.balance()
    tx = strategy.withdrawAll({"from": strategy_vault})
    vault_balance_after = strategy_vault.balance()
    assert tx.return_value > scale(9, decimals)
    expected = vault_balance_after - vault_balance_before + tx.gas_used * tx.gas_price
    assert tx.events["WithdrawAll"]["amount"] == expected
    assert vault_balance_after - vault_balance_before > scale(9, decimals)
    crvRewards = interface.IRewardStaking(strategy.rewards())
    assert crvRewards.balanceOf(strategy) == 0


@pytest.mark.mainnetFork
def test_withdraw_all_with_some_deposited(
    strategy, strategy_vault, decimals, interface
):
    strategy.deposit({"from": strategy_vault, "value": scale(4, decimals)})
    strategy_vault.transfer(strategy, scale(4, decimals))
    vaultBalanceBefore = strategy_vault.balance()
    tx = strategy.withdrawAll({"from": strategy_vault})
    assert tx.return_value > scale(6, decimals)
    assert strategy_vault.balance() - vaultBalanceBefore > scale(7, decimals)
    crvRewards = interface.IRewardStaking(strategy.rewards())
    assert crvRewards.balanceOf(strategy) == 0


@pytest.mark.mainnetFork
def test_withdraw_all_fails_when_curve_imbalanced(
    strategy, strategy_vault, admin, decimals
):
    strategy.setImbalanceToleranceOut(0, {"from": admin})
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    with reverts():
        strategy.withdrawAll({"from": strategy_vault})


@pytest.mark.mainnetFork
def test_harvest_cvx(strategy, admin, strategy_vault, cvx, decimals):
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    cvx.transfer(strategy, scale(10, decimals), {"from": admin})
    tx = strategy.harvest({"from": strategy_vault})
    assert tx.events["Harvest"]["amount"] > 0
    assert strategy.balance() > scale(10, decimals)
    assert tx.return_value > 0


@pytest.mark.mainnetFork
def test_harvest_crv(strategy, admin, crv, strategy_vault, decimals):
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    crv.transfer(strategy, scale(10, decimals), {"from": admin})
    tx = strategy.harvest({"from": strategy_vault})
    assert strategy.balance() > scale(10, decimals)
    assert tx.return_value > 0


@pytest.mark.mainnetFork
def test_harvest_reward_tokens(strategy, strategy_vault, decimals, admin, sushi):
    # Depositing
    tx = strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})

    # Adding SUSHI Reward Token
    strategy.addRewardToken(TokenAddresses.SUSHI, {"from": admin})

    # Generating Rewards
    sushi.transfer(strategy, scale(10), {"from": admin})
    assert sushi.balanceOf(strategy) == scale(10)

    # Harvesting
    balanceBefore = strategy.balance()
    tx = strategy.harvest({"from": strategy_vault})
    assert strategy.balance() > balanceBefore
    assert tx.return_value > 0


@pytest.mark.mainnetFork
def test_harvest_rewards(strategy, strategy_vault, chain, decimals, interface):
    # Depositing
    tx = strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})

    # Generating Rewards
    chain.sleep(3 * 86400)

    # Harvesting
    balanceBefore = strategy.balance()
    tx = strategy.harvest({"from": strategy_vault})
    rewards = interface.IRewardBase(strategy.rewards())
    if rewards.periodFinish() > chain.time():
        assert strategy.balance() > balanceBefore
        assert tx.return_value > 0


@pytest.mark.mainnetFork
def test_harvest_gov_share(
    strategy, admin, strategy_vault, charlie, cvx, decimals, crv
):
    # Depositing
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})

    # Adding CVX & CRV
    cvx.transfer(strategy, scale(10, decimals), {"from": admin})
    crv.transfer(strategy, scale(10, decimals), {"from": admin})

    # Setting up reserve
    tx = strategy.setCommunityReserve(charlie, {"from": admin})
    assert tx.events["SetCommunityReserve"]["reserve"] == charlie
    tx = strategy.setCrvCommunityReserveShare(scale(0.5, decimals), {"from": admin})
    assert tx.events["SetCrvCommunityReserveShare"]["value"] == scale(0.5, decimals)
    tx = strategy.setCvxCommunityReserveShare(scale(0.2, decimals), {"from": admin})
    assert tx.events["SetCvxCommunityReserveShare"]["value"] == scale(0.2, decimals)

    # Harvesting
    cvxBalanceBefore = cvx.balanceOf(charlie)
    crvBalanceBefore = crv.balanceOf(charlie)
    strategy.harvest({"from": strategy_vault})
    reserveCvx = cvx.balanceOf(charlie) - cvxBalanceBefore
    reserveCrv = crv.balanceOf(charlie) - crvBalanceBefore
    assert reserveCvx > 0
    assert reserveCrv > 0
    assert pytest.approx(reserveCvx, abs=1e14) == scale(2, decimals)
    assert pytest.approx(reserveCrv, abs=1e14) == scale(5, decimals)


@pytest.mark.mainnetFork
def test_harvestable_empty(strategy):
    assert strategy.harvestable() == 0


@pytest.mark.mainnetFork
def test_harvestable(
    strategy,
    admin,
    decimals,
    strategy_vault,
    MeroEthCvx,
    alice,
    chain,
    interface,
    address_provider,
):
    # Depositing
    tx = strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})

    # depositing from second strategy
    # this is used so we can trigger a claim reward to refresh the Convex Rewards `earned()` calc
    second_strategy = admin.deploy(
        MeroEthCvx,
        strategy_vault,
        alice,
        convex_pid,
        curve_pool_address,
        curve_index,
        address_provider,
    )
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})

    # Generating Rewards
    chain.sleep(3 * 86400)

    # update `earned()` calc by harvesting from second strategy
    second_strategy.harvest({"from": strategy_vault})

    # Checking harvestable
    harvestable = strategy.harvestable()
    tx = strategy.harvest({"from": strategy_vault})
    difference = abs(tx.return_value - harvestable)

    rewards = interface.IRewardBase(strategy.rewards())
    if rewards.periodFinish() > chain.time():
        assert difference / max(tx.return_value, harvestable) < 0.3
        assert harvestable > 0
        assert tx.return_value > 0


@pytest.mark.mainnetFork
def test_has_pending_funds(strategy):
    assert strategy.hasPendingFunds() == False


@pytest.mark.mainnetFork
def test_returns_false_adding_already_added_reward_token(strategy, admin, sushi):
    tx = strategy.addRewardToken(sushi, {"from": admin})
    assert tx.return_value == True
    assert tx.events["AddRewardToken"]["token"] == sushi
    tx = strategy.addRewardToken(sushi, {"from": admin})
    assert tx.return_value == False


@pytest.mark.mainnetFork
def test_harvesting_reward_token(strategy, admin, sushi, decimals, strategy_vault):
    strategy.addRewardToken(sushi, {"from": admin})
    strategy.deposit({"from": strategy_vault, "value": scale(10, decimals)})
    sushi.transfer(strategy, scale(10, decimals), {"from": admin})
    assert sushi.balanceOf(strategy) == scale(10, decimals)
    tx = strategy.harvest({"from": strategy_vault})
    assert strategy.balance() > scale(10, decimals)
    assert tx.return_value > 0
    assert sushi.balanceOf(strategy) == 0


@pytest.mark.mainnetFork
def test_removing_reward_token_that_doesnt_exist(strategy, admin, sushi):
    tx = strategy.removeRewardToken(sushi, {"from": admin})
    assert tx.return_value == False


@pytest.mark.mainnetFork
def test_removing_reward_token(strategy, admin, sushi):
    strategy.addRewardToken(sushi, {"from": admin})
    tx = strategy.removeRewardToken(sushi, {"from": admin})
    assert tx.events["RemoveRewardToken"]["token"] == sushi
