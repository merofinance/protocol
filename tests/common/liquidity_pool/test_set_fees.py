import brownie
import pytest
from support.convert import format_to_bytes


def test_set_max_withdrawal_fee(admin, pool):
    newFee = 0.05 * 1e18
    expected_key = format_to_bytes("MaxWithdrawalFee", 32, True)
    pool.setMinWithdrawalFee(0)
    pool.setMaxWithdrawalFee(0)

    pool.updateMaxWithdrawalFee(newFee, {"from": admin})
    assert pool.maxWithdrawalFee() == newFee


@pytest.mark.parametrize("fee", [0.2, 0.5, 0.06, 1])
def test_fail_withdrawal_fee_too_high(admin, pool, fee):
    # dev: attempt to set withdrawal fee > 5%
    invalidFee = 1e18 * fee
    with brownie.reverts("invalid amount"):
        pool.updateMaxWithdrawalFee(invalidFee, {"from": admin})
