import pytest

from brownie.test.managers.runner import RevertContextManager as reverts
from brownie import ZERO_ADDRESS

from support.mainnet_contracts import VendorAddresses


@pytest.fixture(scope="module")
def dummyContract(DummyContract, admin):
    return admin.deploy(DummyContract)


def test_has_no_calls_by_default(governanceTimelock):
    assert len(governanceTimelock.pendingCalls()) == 0


def test_preparing_call_fails_for_non_owner(governanceTimelock, alice, dummyContract):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Ownable: caller is not the owner"):
        governanceTimelock.prepareCall(ZERO_ADDRESS, DATA, True, {"from": alice})


def test_preparing_reverts_for_zero_address(governanceTimelock, admin, dummyContract):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Zero address not allowed"):
        governanceTimelock.prepareCall(ZERO_ADDRESS, DATA, False, {"from": admin})


def test_preparing_call(governanceTimelock, admin, dummyContract):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.CONVEX_BOOSTER, DATA, False, {"from": admin}
    )
    assert len(governanceTimelock.pendingCalls()) == 1
    assert governanceTimelock.totalCalls() == 1
    governanceTimelock.prepareCall(
        VendorAddresses.AAVE_LENDING_POOL, DATA, False, {"from": admin}
    )
    calls = governanceTimelock.pendingCalls()
    assert len(calls) == 2
    assert calls[0][0] == 0
    assert calls[0][2] == VendorAddresses.CONVEX_BOOSTER
    assert calls[0][3] == SIGNAURE
    assert calls[0][4] == DATA
    assert calls[1][0] == 1
    assert calls[1][2] == VendorAddresses.AAVE_LENDING_POOL
    assert calls[1][3] == SIGNAURE
    assert calls[1][4] == DATA
    assert governanceTimelock.pendingCallIndex(1) == 1
    assert governanceTimelock.pendingCallIndex(0) == 0
    assert governanceTimelock.pendingCall(0)[2] == VendorAddresses.CONVEX_BOOSTER
    assert governanceTimelock.pendingCall(1)[2] == VendorAddresses.AAVE_LENDING_POOL
    assert governanceTimelock.totalCalls() == 2


def test_execute_fails_for_non_existant_call(governanceTimelock, admin, dummyContract):
    with reverts("Call not found"):
        governanceTimelock.executeCall(0, {"from": admin})


def test_execute_call(governanceTimelock, admin, dummyContract):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(dummyContract, DATA, False, {"from": admin})
    assert dummyContract.value() == 0
    assert len(governanceTimelock.executedCalls()) == 0
    governanceTimelock.executeCall(0, {"from": admin})
    assert dummyContract.value() == 1
    assert len(governanceTimelock.pendingCalls()) == 0
    calls = governanceTimelock.executedCalls()
    assert len(calls) == 1
    assert calls[0][0] == 0
    assert calls[0][2] == dummyContract
    assert calls[0][3] == SIGNAURE
    assert calls[0][4] == DATA
    assert governanceTimelock.totalCalls() == 1


def test_set_delay(governanceTimelock, admin, dummyContract):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    assert governanceTimelock.delays(dummyContract, SIGNAURE) == 0
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})
    assert governanceTimelock.delays(dummyContract, SIGNAURE) == DELAY


def test_execute_fails_when_delay_not_ready(governanceTimelock, admin, dummyContract):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})

    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(dummyContract, DATA, False, {"from": admin})
    with reverts("Call not ready"):
        governanceTimelock.executeCall(0, {"from": admin})


def test_execute_call_with_signature_delay(
    governanceTimelock, admin, dummyContract, chain
):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})

    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(dummyContract, DATA, True, {"from": admin})
    assert dummyContract.value() == 0
    chain.sleep(DELAY)
    governanceTimelock.executeCall(0, {"from": admin})
    assert dummyContract.value() == 1


def test_cancel_fails_for_non_admin(governanceTimelock, alice, dummyContract, admin):
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.CONVEX_BOOSTER, DATA, False, {"from": admin}
    )
    with reverts("Ownable: caller is not the owner"):
        governanceTimelock.cancelCall(0, {"from": alice})


def test_cancel_call(governanceTimelock, admin, dummyContract):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(dummyContract, DATA, True, {"from": admin})
    assert len(governanceTimelock.pendingCalls()) == 1
    assert len(governanceTimelock.cancelledCalls()) == 0
    governanceTimelock.cancelCall(0, {"from": admin})
    assert len(governanceTimelock.pendingCalls()) == 0
    calls = governanceTimelock.cancelledCalls()
    assert len(calls) == 1
    assert calls[0][0] == 0
    assert calls[0][2] == dummyContract
    assert calls[0][3] == SIGNAURE
    assert calls[0][4] == DATA
    assert governanceTimelock.totalCalls() == 1


def test_duplicate_preparing_call_reverts(governanceTimelock, admin, dummyContract):
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.CONVEX_BOOSTER, DATA, False, {"from": admin}
    )
    DATA = dummyContract.updateValue.encode_input(2)
    with reverts("Call already pending"):
        governanceTimelock.prepareCall(
            VendorAddresses.CONVEX_BOOSTER, DATA, True, {"from": admin}
        )


def test_quick_execute_call_reverts_for_non_owner(
    governanceTimelock, dummyContract, alice
):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Ownable: caller is not the owner"):
        governanceTimelock.quickExecuteCall(
            VendorAddresses.CONVEX_BOOSTER, DATA, {"from": alice}
        )


def test_quick_execute_call_reverts_for_zero_address(
    governanceTimelock, dummyContract, admin
):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Zero address not allowed"):
        governanceTimelock.quickExecuteCall(ZERO_ADDRESS, DATA, {"from": admin})


def test_quick_execute_call_reverts_for_already_pending_duplicate(
    governanceTimelock, dummyContract, admin
):
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.CONVEX_BOOSTER, DATA, False, {"from": admin}
    )
    DATA = dummyContract.updateValue.encode_input(2)
    with reverts("Call already pending"):
        governanceTimelock.quickExecuteCall(
            VendorAddresses.CONVEX_BOOSTER, DATA, {"from": admin}
        )


def test_quick_execute_call_reverts_for_signature_delay(
    governanceTimelock, dummyContract, admin, chain
):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})

    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Call has a delay"):
        governanceTimelock.quickExecuteCall(dummyContract, DATA, {"from": admin})
    chain.sleep(DELAY)
    with reverts("Call has a delay"):
        governanceTimelock.quickExecuteCall(dummyContract, DATA, {"from": admin})


def test_quick_execute_call(governanceTimelock, dummyContract, admin):
    DATA = dummyContract.updateValue.encode_input(1)
    assert dummyContract.value() == 0
    governanceTimelock.quickExecuteCall(dummyContract, DATA, {"from": admin})
    assert dummyContract.value() == 1


def test_setting_contract_delay_twice_reverts(governanceTimelock, dummyContract, admin):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})
    DELAY = 4 * 86400
    with reverts("Delay already set"):
        governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})


def test_updating_contract_delay_reverts_when_not_already_set(
    governanceTimelock, dummyContract, admin
):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    DATA = governanceTimelock.updateDelay.encode_input(dummyContract, SIGNAURE, DELAY)
    governanceTimelock.prepareCall(governanceTimelock, DATA, False, {"from": admin})
    with reverts("Delay not already set"):
        governanceTimelock.executeCall(0, {"from": admin})


def test_updating_target_delay_reverts_from_non_self(
    governanceTimelock, dummyContract, admin
):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})
    DELAY = 4 * 86400
    with reverts("Must be called via timelock"):
        governanceTimelock.updateDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})


def test_updating_contract_delay(governanceTimelock, dummyContract, admin, chain):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})
    assert governanceTimelock.delays(dummyContract, SIGNAURE) == DELAY
    NEW_DELAY = 4 * 86400
    DATA = governanceTimelock.updateDelay.encode_input(
        dummyContract, SIGNAURE, NEW_DELAY
    )
    governanceTimelock.prepareCall(governanceTimelock, DATA, True, {"from": admin})
    chain.sleep(DELAY)
    governanceTimelock.executeCall(0, {"from": admin})
    assert governanceTimelock.delays(dummyContract, SIGNAURE) == NEW_DELAY


def test_updating_contract_delay_not_ready(governanceTimelock, dummyContract, admin):
    SIGNAURE = dummyContract.signatures["updateValue"]
    DELAY = 3 * 86400
    governanceTimelock.setDelay(dummyContract, SIGNAURE, DELAY, {"from": admin})
    assert governanceTimelock.delays(dummyContract, SIGNAURE) == DELAY
    NEW_DELAY = 4 * 86400
    DATA = governanceTimelock.updateDelay.encode_input(
        dummyContract, SIGNAURE, NEW_DELAY
    )
    governanceTimelock.prepareCall(governanceTimelock, DATA, True, {"from": admin})
    with reverts("Call not ready"):
        governanceTimelock.executeCall(0, {"from": admin})


def test_pending_call_delay(governanceTimelock, dummyContract, admin):
    DELAY = 3 * 86400
    governanceTimelock.setDelay(
        dummyContract, dummyContract.signatures["updateValue"], DELAY, {"from": admin}
    )
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(dummyContract, DATA, False, {"from": admin})
    assert governanceTimelock.pendingCallDelay(0) == DELAY


def test_ready_and_not_ready_calls(governanceTimelock, admin, dummyContract, chain):
    DELAY = 3 * 86400
    governanceTimelock.setDelay(
        VendorAddresses.CONVEX_BOOSTER,
        dummyContract.signatures["updateValue"],
        DELAY,
        {"from": admin},
    )
    governanceTimelock.setDelay(
        VendorAddresses.AAVE_LENDING_POOL,
        dummyContract.signatures["updateValue"],
        DELAY,
        {"from": admin},
    )

    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.CONVEX_BOOSTER, DATA, False, {"from": admin}
    )
    chain.sleep(2 * 86400)
    governanceTimelock.prepareCall(
        VendorAddresses.AAVE_LENDING_POOL, DATA, False, {"from": admin}
    )
    chain.sleep(2 * 86400)
    chain.mine()
    ready = governanceTimelock.readyCalls()
    assert len(ready) == 1
    not_ready = governanceTimelock.readyCalls()
    assert len(not_ready) == 1


def test_test_call_is_not_callable(governanceTimelock, admin):
    with reverts("Only callable by this contract"):
        governanceTimelock.testCall(
            (1, 1, VendorAddresses.AAVE_LENDING_POOL, "", ""), {"from": admin}
        )


def test_validate_reverts_when_validating_for_non_existing_contract(
    governanceTimelock, admin, dummyContract
):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Call would revert when executed: invalid contract"):
        governanceTimelock.prepareCall(
            VendorAddresses.AAVE_LENDING_POOL, DATA, True, {"from": admin}
        )


def test_validate_reverts_when_validating_for_non_existing_function(
    governanceTimelock, admin, dummyContract
):
    DATA = dummyContract.updateValue.encode_input(1)
    with reverts("Call would revert when executed: Address: low-level call failed"):
        governanceTimelock.prepareCall(governanceTimelock, DATA, True, {"from": admin})


def test_validate_reverts_when_validating_for_reverting_function(
    governanceTimelock, admin, dummyContract
):
    DATA = dummyContract.justRevert.encode_input(1)
    with reverts("Call would revert when executed: I just revert"):
        governanceTimelock.prepareCall(dummyContract, DATA, True, {"from": admin})


def test_validate_doesnt_revert_when_not_validating(
    governanceTimelock, admin, dummyContract
):
    DATA = dummyContract.updateValue.encode_input(1)
    governanceTimelock.prepareCall(
        VendorAddresses.AAVE_LENDING_POOL, DATA, False, {"from": admin}
    )
