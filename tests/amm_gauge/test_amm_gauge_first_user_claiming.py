import pytest
from support.constants import ADMIN_DELAY, AddressProviderKeys

from support.utils import scale


@pytest.fixture(autouse=True)
def bootstrap_gauge_inflation(
    ammGauge, admin, chain, mockAmmToken, inflation_manager, minter, request
):
    request.getfixturevalue("meroToken")

    inflation_manager.setMinter(minter, {"from": admin})
    inflation_manager.setAmmGauge(mockAmmToken, ammGauge, {"from": admin})
    inflation_manager.updateAmmTokenWeight(mockAmmToken, 0.4 * 1e18, {"from": admin})


def test_checkpoint(
    ammGauge,
    chain,
    alice,
    bob,
    charlie,
    david,
    mockAmmToken,
    address_provider,
    MockInflationManager,
):
    secure_checkpoint = False
    print(address_provider.getAddress(AddressProviderKeys.INFLATION_MANAGER_KEY.value))
    print(MockInflationManager[0])

    users = [alice, bob, charlie, david]

    ammGauge.poolCheckpoint()
    chain.sleep(1 * 24 * 60 * 60)  # 1 day

    def stake(to, amount):
        # Balance before
        balance_before = ammGauge.balances(to)
        # Stake
        mockAmmToken.mint(to, amount)
        mockAmmToken.approve(ammGauge, amount, {"from": to})
        ammGauge.stake(amount, {"from": to})
        assert ammGauge.balances(to) == balance_before + amount

    # Each user stakes tokens
    staked_amount = scale("10")
    for user in users:
        stake(user, staked_amount)
        if secure_checkpoint:
            ammGauge.poolCheckpoint()
        chain.sleep(60 * 60)  # 1hr between stakes

    chain.sleep(5 * 24 * 60 * 60)  # 5 days
    chain.mine()

    if secure_checkpoint:
        ammGauge.poolCheckpoint()

    claimable_rewards = []
    claimed_rewards = []

    for user in users:
        claimable = ammGauge.claimableRewards(user)
        claimable_rewards.append(claimable / 1e18)

        tx = ammGauge.claimRewards(user, {"from": user})
        claimed_rewards.append(tx.events["RewardClaimed"]["amount"] / 1e18)

    print("Claimable calculated")
    print("   ALICE - BOB -  CHARLIE - DAVID")
    print(claimable_rewards)

    print(" ")
    print("Effectively Claimed")
    print("   ALICE - BOB -  CHARLIE - DAVID")
    print(claimed_rewards)
