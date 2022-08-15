from brownie.test.managers.runner import RevertContextManager as reverts
import pytest
from support.utils import scale


def test_update_required_staked_mero_fails_without_mero_locker(controller, admin):
    with reverts("address does not exist"):
        controller.updateKeeperRequiredStakedMERO(scale(10), {"from": admin})


@pytest.mark.usefixtures("set_mero_locker_to_mock_token")
def test_update_required_staked_mero(controller, admin):
    assert controller.keeperRequireStakedMero() == 0
    controller.updateKeeperRequiredStakedMERO(scale(10), {"from": admin})
    assert controller.keeperRequireStakedMero() == scale(10)


@pytest.mark.usefixtures("set_mero_locker_to_mock_token")
def test_keeper_cannot_execute_action_without_tokens(
    controller, alice, admin
):
    controller.updateKeeperRequiredStakedMERO(scale(10), {"from": admin})
    assert not controller.canKeeperExecuteAction(alice)


@pytest.mark.usefixtures("set_mero_locker_to_mock_token")
def test_keeper_can_execute_action_with_tokens(
    controller, alice, mockToken, admin
):
    controller.updateKeeperRequiredStakedMERO(scale(10), {"from": admin})
    mockToken.mintFor(alice, scale(10), {"from": alice})
    assert controller.canKeeperExecuteAction(alice)
