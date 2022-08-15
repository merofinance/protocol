from brownie.test.managers.runner import RevertContextManager as reverts
import pytest


ADMIN_DELAY = 3 * 86400
TEST_DELAY = 1 * 86400
WITHDRAW_DELAY = 10 * 86400
INCREASE_DELAY = 20 * 86400


@pytest.fixture
def setup_mero_locker(admin, meroLocker):
    meroLocker.initialize(1e18, 5e18, INCREASE_DELAY, WITHDRAW_DELAY)


@pytest.fixture
def setup_mero_locker_no_boost(admin, meroLocker):
    meroLocker.initialize(1e18, 1e18, INCREASE_DELAY, WITHDRAW_DELAY)


@pytest.mark.usefixtures("setup_mero_locker")
def test_can_lock_and_unlock_tokens(
    admin, alice, bob, meroToken, meroLocker, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    balance_before = meroToken.balanceOf(alice)
    tx = meroLocker.lock(50e18, {"from": alice})
    balance_after = meroToken.balanceOf(alice)
    assert balance_before - balance_after == 50e18
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 50e18

    tx = meroLocker.prepareUnlock(50e18, {"from": alice})
    assert tx.events["WithdrawPrepared"][0]["user"] == alice
    assert tx.events["WithdrawPrepared"][0]["amount"] == 50e18

    chain.sleep(WITHDRAW_DELAY)
    chain.mine()

    tx = meroLocker.executeUnlocks({"from": alice})
    assert balance_before == meroToken.balanceOf(alice)
    assert tx.events["WithdrawExecuted"][0]["user"] == alice
    assert tx.events["WithdrawExecuted"][0]["amount"] == 50e18


@pytest.mark.usefixtures("setup_mero_locker")
def test_can_lock_and_unlock_tokens_piecewise(
    admin, alice, bob, meroToken, meroLocker, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    tx = meroLocker.lock(80e18, {"from": alice})
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 80e18

    tx = meroLocker.prepareUnlock(50e18, {"from": alice})
    assert tx.events["WithdrawPrepared"][0]["user"] == alice
    assert tx.events["WithdrawPrepared"][0]["amount"] == 50e18

    chain.sleep(int(0.5 * WITHDRAW_DELAY))
    chain.mine()

    tx = meroLocker.prepareUnlock(30e18, {"from": alice})
    assert tx.events["WithdrawPrepared"][0]["user"] == alice
    assert tx.events["WithdrawPrepared"][0]["amount"] == 30e18

    chain.sleep(int(0.5 * WITHDRAW_DELAY))
    chain.mine()

    tx = meroLocker.executeUnlocks({"from": alice})
    assert tx.events["WithdrawExecuted"][0]["user"] == alice
    assert tx.events["WithdrawExecuted"][0]["amount"] == 50e18

    chain.sleep(int(0.5 * WITHDRAW_DELAY))
    chain.mine()

    tx = meroLocker.executeUnlocks({"from": alice})
    assert tx.events["WithdrawExecuted"][0]["user"] == alice
    assert tx.events["WithdrawExecuted"][0]["amount"] == 30e18


@pytest.mark.usefixtures("setup_mero_locker")
def test_boosted_balance_computes_correctly(alice, meroToken, meroLocker, minter, chain):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    tx = meroLocker.lock(100e18, {"from": alice})
    assert meroLocker.boostedBalance(alice) == 100e18

    chain.sleep(INCREASE_DELAY)
    meroLocker.userCheckpoint(alice)
    assert meroLocker.boostedBalance(alice) == 500e18


@pytest.mark.usefixtures("setup_mero_locker")
def test_share_of_boosted_balance_computes_correctly(
    admin, alice, bob, meroToken, meroLocker, minter, pool, chain
):
    minter.mint_for_testing(alice, 150e18)
    meroToken.approve(meroLocker, 150e18, {"from": alice})
    tx = meroLocker.lock(150e18, {"from": alice})
    assert meroLocker.boostedBalance(alice) == 150e18

    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})
    tx = meroLocker.lock(50e18, {"from": bob})
    assert meroLocker.boostedBalance(bob) == 50e18

    assert meroLocker.getShareOfTotalBoostedBalance(alice) == 0.75 * 1e18
    assert meroLocker.getShareOfTotalBoostedBalance(bob) == 0.25 * 1e18


@pytest.mark.usefixtures("setup_mero_locker")
def test_boosting_factor_initialised_correctly(
    admin, alice, bob, meroToken, meroLocker, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    tx = meroLocker.lock(100e18, {"from": alice})
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 100e18
    assert meroLocker.boostedBalance(alice) == 100e18

    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})
    tx = meroLocker.lock(50e18, {"from": bob})
    assert tx.events["Locked"][0]["user"] == bob
    assert tx.events["Locked"][0]["amount"] == 50e18
    assert meroLocker.boostedBalance(bob) == 50e18


@pytest.mark.usefixtures("setup_mero_locker")
def test_boosting_factor_increases_and_decreases_correctly(
    admin, alice, bob, meroToken, meroLocker, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    tx = meroLocker.lock(100e18, {"from": alice})
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 100e18
    assert meroLocker.boostedBalance(alice) == 100e18
    assert meroLocker.totalLocked() == 100e18
    assert meroLocker.totalLockedBoosted() == 100e18

    chain.sleep(WITHDRAW_DELAY)
    chain.mine()

    meroLocker.userCheckpoint(alice)

    expected_boosted_amount = (4 * 0.5 + 1) * 100e18
    assert (
        pytest.approx(meroLocker.boostedBalance(alice), abs=1e18)
        == expected_boosted_amount
    )
    assert meroLocker.totalLocked() == 100e18
    assert (
        pytest.approx(meroLocker.totalLockedBoosted(), abs=1e18)
        == expected_boosted_amount
    )

    minter.mint_for_testing(alice, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": alice})
    tx = meroLocker.lock(50e18, {"from": alice})
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 50e18
    new_expected_boosted_amount = expected_boosted_amount + 50e18
    assert (
        pytest.approx(meroLocker.boostedBalance(alice), abs=1e18)
        == new_expected_boosted_amount
    )
    assert meroLocker.totalLocked() == 150e18
    assert (
        pytest.approx(meroLocker.totalLockedBoosted(), abs=1e18)
        == new_expected_boosted_amount
    )


@pytest.mark.usefixtures("setup_mero_locker")
def test_single_depositor_gets_all_fees(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    tx = meroLocker.lock(100e18, {"from": alice})
    # start_time = meroLocker.lastGlobalUpdate()
    start_time = chain[-1]["timestamp"]
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 100e18
    assert meroLocker.boostedBalance(alice) == 100e18
    chain.sleep(10)
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})

    fee_time = chain[-1]["timestamp"]
    assert meroLocker.totalLockedBoosted() == 100e18

    chain.sleep(10)
    chain.mine()

    meroLocker.userCheckpoint(alice)
    end_time = chain[-1]["timestamp"]

    # If locking and fee deposit occurs in the same block, alice is not entitled to a share
    if fee_time == start_time:
        alice_share = 0
    else:
        alice_share = 10e18

    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e10) == alice_share
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice
    assert pytest.approx(lpToken.balanceOf(alice), abs=1e10) == alice_share


@pytest.mark.usefixtures("setup_mero_locker_no_boost")
def test_fees_distributed_correctly_no_boost(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    tx = meroLocker.lock(100e18, {"from": alice})
    assert tx.events["Locked"][0]["user"] == alice
    assert tx.events["Locked"][0]["amount"] == 100e18
    assert meroLocker.boostedBalance(alice) == 100e18
    alice_lock_time = chain[-1]["timestamp"]

    tx = meroLocker.lock(50e18, {"from": bob})
    assert tx.events["Locked"][0]["user"] == bob
    assert tx.events["Locked"][0]["amount"] == 50e18
    assert meroLocker.boostedBalance(bob) == 50e18
    bob_lock_time = chain[-1]["timestamp"]

    assert meroLocker.totalLocked() == 150e18
    assert meroLocker.totalLockedBoosted() == 150e18

    chain.sleep(1)
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})
    fee_time = chain[-1]["timestamp"]

    I_fees = 10e36 / 150e18

    share_alice = 100e18 * I_fees / 1e18

    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e12) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 50e18 * I_fees / 1e18

    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e12) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob

    chain.sleep(TEST_DELAY)
    chain.mine()

    lpToken.mint_for_testing(charlie, 20e18)
    lpToken.approve(meroLocker, 20e18, {"from": charlie})
    meroLocker.depositFees(20e18, {"from": charlie})
    I_fees_new = I_fees + 20e36 / 150e18

    share_alice_new = 100e18 * (I_fees_new - I_fees) / 1e18
    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e12)
        == share_alice_new
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob_new = 50e18 * (I_fees_new - I_fees) / 1e18
    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e12)
        == share_bob_new
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_distributed_correctly_with_boost_pre_deposit(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):

    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})
    alice_lock_time = chain[-1]["timestamp"]

    meroLocker.lock(50e18, {"from": bob})
    bob_lock_time = chain[-1]["timestamp"]

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    meroLocker.userCheckpoint(alice)
    alice_checkpoint_time = chain[-1]["timestamp"]

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})
    fee_time = chain[-1]["timestamp"]

    alice_boosted_balance = 100e18 * (4 * 0.5 + 1)
    I_fees = 10e36 / (alice_boosted_balance + 50e18)
    share_alice = alice_boosted_balance * I_fees / 1e18

    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 50e18 * I_fees / 1e18

    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_distributed_correctly_with_boost_post_deposit(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})
    alice_lock_time = chain[-1]["timestamp"]

    meroLocker.lock(50e18, {"from": bob})
    bob_lock_time = chain[-1]["timestamp"]

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})

    meroLocker.userCheckpoint(alice)

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    I_fees = 10e36 / 150e18
    share_alice = 100e18 * I_fees / 1e18

    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 50e18 * I_fees / 1e18

    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_distributed_correctly_with_withdrawal_prep_pre_deposit(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})
    alice_lock_time = chain[-1]["timestamp"]

    meroLocker.lock(50e18, {"from": bob})
    bob_lock_time = chain[-1]["timestamp"]

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    meroLocker.prepareUnlock(50e18, {"from": alice})

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})
    fee_time = chain[-1]["timestamp"]

    I_pool = (bob_lock_time - alice_lock_time) * 100e18 + (
        fee_time - bob_lock_time
    ) * 150e18
    I_fees = 10e18 / I_pool
    share_alice = ((fee_time - alice_lock_time) * 100e18) * I_fees

    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = (fee_time - bob_lock_time) * 50e18 * I_fees

    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_distributed_correctly_with_withdrawal_execution_pre_deposit(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})

    meroLocker.lock(50e18, {"from": bob})

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    meroLocker.prepareUnlock(100e18, {"from": alice})

    chain.sleep(WITHDRAW_DELAY)
    chain.mine()

    meroLocker.executeUnlocks({"from": alice})

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})

    tx = meroLocker.claimFees({"from": alice})
    assert tx.events["RewardsClaimed"][0]["amount"] == 0
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 10e18

    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_distributed_correctly_with_no_locked_at_deposit(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})

    meroLocker.lock(50e18, {"from": bob})

    meroLocker.prepareUnlock(100e18, {"from": alice})
    chain.sleep(int(WITHDRAW_DELAY * 0.5))
    chain.mine()

    meroLocker.prepareUnlock(50e18, {"from": bob})
    chain.sleep(int(WITHDRAW_DELAY * 0.5))
    chain.mine()

    meroLocker.executeUnlocks({"from": alice})

    chain.sleep(int(WITHDRAW_DELAY * 0.5))
    chain.mine()
    meroLocker.executeUnlocks({"from": bob})

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    with reverts("not enough funds to withdraw"):
        meroLocker.depositFees(10e18, {"from": charlie})


@pytest.mark.usefixtures("setup_mero_locker")
def test_claimable_fees_in_agreement_with_claimed(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})

    meroLocker.lock(50e18, {"from": bob})

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})

    claimable_alice_checkpoint = meroLocker.claimableFees(alice)
    meroLocker.userCheckpoint(alice)
    # assert claimable_alice_checkpoint == meroLocker.userShares(alice)

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    I_fees = 10e36 / 150e18
    share_alice = 100e18 * I_fees / 1e18

    claimable_alice = meroLocker.claimableFees(alice)
    assert pytest.approx(claimable_alice, abs=1e14) == share_alice
    tx = meroLocker.claimFees({"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 50e18 * I_fees / 1e18

    claimable_bob = meroLocker.claimableFees(bob)
    assert pytest.approx(claimable_bob, abs=1e14) == share_bob
    tx = meroLocker.claimFees({"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_vote_weight_correctly_responds_to_stashing(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})
    alice_lock_time = chain[-1]["timestamp"]

    meroLocker.lock(50e18, {"from": bob})
    bob_lock_time = chain[-1]["timestamp"]

    assert pytest.approx(meroLocker.balanceOf(alice), abs=1e10) == 100e18
    assert pytest.approx(meroLocker.balanceOf(bob), abs=1e10) == 50e18

    meroLocker.prepareUnlock(50e18, {"from": alice})

    assert pytest.approx(meroLocker.balanceOf(alice), abs=1e10) == 50e18
    chain.sleep(int(WITHDRAW_DELAY * 0.5))
    chain.mine()

    meroLocker.prepareUnlock(50e18, {"from": bob})
    assert meroLocker.balanceOf(bob) == 0
    chain.sleep(int(WITHDRAW_DELAY * 0.5))
    chain.mine()

    meroLocker.userCheckpoint(alice)
    checkpoint_time = chain[-1]["timestamp"]
    alice_boost = (checkpoint_time - alice_lock_time) / INCREASE_DELAY * 4 + 1
    assert pytest.approx(meroLocker.balanceOf(alice), abs=1e10) == 50e18 * alice_boost

    meroLocker.executeUnlocks({"from": alice})
    alice_unlock_time = chain[-1]["timestamp"]
    alice_boost = (alice_unlock_time - alice_lock_time) / INCREASE_DELAY * 4 + 1
    assert meroLocker.accountInfo(alice)["balance"] == 50e18
    assert pytest.approx(meroLocker.accountInfo(alice)["boostFactor"], abs=1e10) == alice_boost * 1e18
    assert pytest.approx(meroLocker.balanceOf(alice), abs=1e10) == 50e18 * alice_boost

    meroLocker.prepareUnlock(50e18, {"from": alice})
    assert meroLocker.balanceOf(alice) == 0


@pytest.mark.usefixtures("setup_mero_locker")
def test_withdrawal_correctly_updates_state(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})

    meroLocker.lock(50e18, {"from": bob})

    meroLocker.prepareUnlock(50e18, {"from": alice})
    meroLocker.prepareUnlock(20e18, {"from": alice})

    meroLocker.prepareUnlock(50e18, {"from": bob})
    chain.sleep(int(WITHDRAW_DELAY))
    chain.mine()

    meroLocker.prepareUnlock(10e18, {"from": alice})

    tx = meroLocker.executeUnlocks({"from": alice})
    assert tx.events["WithdrawExecuted"]["amount"] == 70e18
    assert meroLocker.totalLocked() == 80e18
    alice_stashed_gov_tokens = meroLocker.getStashedGovTokens(alice)
    assert len(alice_stashed_gov_tokens) == 1
    assert alice_stashed_gov_tokens[0][1] == 10e18

    tx = meroLocker.executeUnlocks({"from": bob})
    assert tx.events["WithdrawExecuted"]["amount"] == 50e18
    assert meroLocker.totalLocked() == 30e18
    assert len(meroLocker.getStashedGovTokens(bob)) == 0


@pytest.mark.usefixtures("setup_mero_locker")
def test_multiple_fee_deposits(
    admin, alice, bob, charlie, meroToken, meroLocker, lpToken, minter, pool, chain
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})
    lpToken.mint_for_testing(charlie, 100e18)
    lpToken.approve(meroLocker, 100e18, {"from": charlie})

    meroLocker.lock(50e18, {"from": bob})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})
    meroLocker.lock(100e18, {"from": alice})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    meroLocker.userCheckpoint(alice, {"from": admin})
    meroLocker.userCheckpoint(bob, {"from": admin})

    alice_share = meroLocker.getUserShare(alice)
    bob_share = meroLocker.getUserShare(bob)

    assert int(bob_share) == pytest.approx(10e18 + 10e18 / 3, abs=1e12)
    assert int(alice_share) == pytest.approx(10e18 * 2 / 3, abs=1e12)


@pytest.mark.usefixtures("setup_mero_locker")
def test_fees_remain_claimable_after_migration_and_new_accumulation_started(
    admin,
    alice,
    bob,
    charlie,
    meroToken,
    meroLocker,
    lpToken,
    minter,
    pool,
    cappedLpToken,
    chain,
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": bob})
    lpToken.mint_for_testing(charlie, 100e18)
    lpToken.approve(meroLocker, 100e18, {"from": charlie})
    cappedLpToken.mint_for_testing(charlie, 100e18)
    cappedLpToken.approve(meroLocker, 100e18, {"from": charlie})

    meroLocker.lock(50e18, {"from": bob})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})
    meroLocker.lock(100e18, {"from": alice})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    alice_share = meroLocker.getUserShare(alice)
    bob_share = meroLocker.getUserShare(bob)

    assert int(bob_share) == 0
    assert int(alice_share) == 0

    meroLocker.migrate(cappedLpToken, {"from": admin})
    chain.sleep(10)

    meroLocker.userCheckpoint(alice, {"from": admin})
    meroLocker.userCheckpoint(bob, {"from": admin})

    assert int(meroLocker.getUserShare(bob)) == 0
    assert int(meroLocker.getUserShare(alice)) == 0

    assert int(meroLocker.getUserShare(bob, lpToken)) == pytest.approx(
        10e18 + 10e18 / 3, abs=1e12
    )
    assert int(meroLocker.getUserShare(alice, lpToken)) == pytest.approx(
        10e18 * 2 / 3, abs=1e12
    )

    meroLocker.lock(50e18, {"from": bob})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    meroLocker.userCheckpoint(alice, {"from": admin})
    meroLocker.userCheckpoint(bob, {"from": admin})

    assert int(meroLocker.getUserShare(bob)) == pytest.approx(10e18, abs=1e16)
    assert int(meroLocker.getUserShare(alice)) == pytest.approx(10e18, abs=1e16)

    assert int(meroLocker.getUserShare(bob, lpToken)) == pytest.approx(
        10e18 + 10e18 / 3, abs=1e16
    )
    assert int(meroLocker.getUserShare(alice, lpToken)) == pytest.approx(
        10e18 * 2 / 3, abs=1e16
    )

    tx = meroLocker.claimFees({"from": bob})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == pytest.approx(
        10e18, abs=1e16
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob
    tx = meroLocker.claimFees({"from": alice})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == pytest.approx(
        10e18, abs=1e16
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    tx = meroLocker.claimFees(lpToken, {"from": bob})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == pytest.approx(
        10e18 + 10e18 / 3, abs=1e16
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob

    tx = meroLocker.claimFees(lpToken, {"from": alice})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == pytest.approx(
        10e18 * 2 / 3, abs=1e16
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice


@pytest.mark.usefixtures("setup_mero_locker")
def test_switching_back_to_old_reward_token_works_correctly(
    admin,
    alice,
    bob,
    charlie,
    meroToken,
    meroLocker,
    lpToken,
    minter,
    pool,
    cappedLpToken,
    chain,
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": bob})
    lpToken.mint_for_testing(charlie, 100e18)
    lpToken.approve(meroLocker, 100e18, {"from": charlie})
    cappedLpToken.mint_for_testing(charlie, 100e18)
    cappedLpToken.approve(meroLocker, 100e18, {"from": charlie})

    # Fees with lpToken
    meroLocker.lock(50e18, {"from": bob})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})
    meroLocker.lock(100e18, {"from": alice})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    assert int(meroLocker.getUserShare(bob)) == 0
    assert int(meroLocker.getUserShare(alice)) == 0

    # Fees with new lp Token
    meroLocker.migrate(cappedLpToken, {"from": admin})
    chain.sleep(10)

    assert int(meroLocker.getUserShare(bob)) == 0
    assert int(meroLocker.getUserShare(alice)) == 0

    meroLocker.lock(50e18, {"from": bob})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    # Fees with old lp Token
    meroLocker.migrate(lpToken, {"from": admin})
    chain.sleep(10)

    meroLocker.depositFees(10e18, {"from": charlie})
    chain.sleep(10)
    meroLocker.depositFees(10e18, {"from": charlie})

    bob_share_lp_token = pytest.approx(10e18 + 10e18 / 3 + 10e18, abs=1e16)
    alice_share_lp_token = pytest.approx(10e18 * 2 / 3 + 10e18, abs=1e16)

    bob_share_capped_token = pytest.approx(10e18, abs=1e16)
    alice_share_capped_token = pytest.approx(10e18, abs=1e16)

    tx = meroLocker.claimFees({"from": bob})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == bob_share_lp_token
    assert tx.events["RewardsClaimed"][0]["user"] == bob
    tx = meroLocker.claimFees({"from": alice})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == alice_share_lp_token
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    tx = meroLocker.claimFees(cappedLpToken, {"from": bob})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == bob_share_capped_token
    assert tx.events["RewardsClaimed"][0]["user"] == bob

    tx = meroLocker.claimFees(cappedLpToken, {"from": alice})
    assert int(tx.events["RewardsClaimed"][0]["amount"]) == alice_share_capped_token
    assert tx.events["RewardsClaimed"][0]["user"] == alice


@pytest.mark.usefixtures("setup_mero_locker")
def test_claimable_fees_in_agreement_with_claimed_for_replaced_token(
    admin,
    alice,
    bob,
    charlie,
    meroToken,
    meroLocker,
    lpToken,
    cappedLpToken,
    minter,
    pool,
    chain,
):
    minter.mint_for_testing(alice, 100e18)
    meroToken.approve(meroLocker, 100e18, {"from": alice})
    minter.mint_for_testing(bob, 50e18)
    meroToken.approve(meroLocker, 50e18, {"from": bob})

    meroLocker.lock(100e18, {"from": alice})
    meroLocker.lock(50e18, {"from": bob})

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    lpToken.mint_for_testing(charlie, 10e18)
    lpToken.approve(meroLocker, 10e18, {"from": charlie})
    meroLocker.depositFees(10e18, {"from": charlie})

    meroLocker.migrate(cappedLpToken, {"from": admin})

    claimable_alice_checkpoint = meroLocker.claimableFees(alice, lpToken)
    meroLocker.userCheckpoint(alice)
    assert claimable_alice_checkpoint == meroLocker.getUserShare(alice, lpToken)

    chain.sleep(int(INCREASE_DELAY * 0.5))
    chain.mine()

    I_fees = 10e36 / 150e18
    share_alice = 100e18 * I_fees / 1e18

    claimable_alice = meroLocker.claimableFees(alice, lpToken)
    assert pytest.approx(claimable_alice, abs=1e14) == share_alice
    tx = meroLocker.claimFees(lpToken, {"from": alice})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_alice
    )
    assert tx.events["RewardsClaimed"][0]["user"] == alice

    share_bob = 50e18 * I_fees / 1e18

    claimable_bob = meroLocker.claimableFees(bob, lpToken)
    assert pytest.approx(claimable_bob, abs=1e14) == share_bob
    tx = meroLocker.claimFees(lpToken, {"from": bob})
    assert (
        pytest.approx(tx.events["RewardsClaimed"][0]["amount"], abs=1e14) == share_bob
    )
    assert tx.events["RewardsClaimed"][0]["user"] == bob


@pytest.mark.usefixtures("setup_mero_locker")
def test_update_start_boost(admin, meroLocker):
    NEW_VALUE = 3e18
    assert meroLocker.startBoost() != NEW_VALUE
    meroLocker.updateStartBoost(NEW_VALUE, {"from": admin})
    assert meroLocker.startBoost() == NEW_VALUE


@pytest.mark.usefixtures("setup_mero_locker")
def test_update_increase_period(admin, meroLocker):
    NEW_VALUE = 3e18
    assert meroLocker.increasePeriod() != NEW_VALUE
    meroLocker.updateIncreasePeriod(NEW_VALUE, {"from": admin})
    assert meroLocker.increasePeriod() == NEW_VALUE


@pytest.mark.usefixtures("setup_mero_locker")
def test_update_withdrawal_delay(admin, meroLocker):
    NEW_VALUE = 3e18
    assert meroLocker.withdrawalDelay() != NEW_VALUE
    meroLocker.updateWithdrawalDelay(NEW_VALUE, {"from": admin})
    assert meroLocker.withdrawalDelay() == NEW_VALUE