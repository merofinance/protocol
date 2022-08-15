import pytest


@pytest.fixture(scope="module")
def newController(
    Controller, admin, address_provider
):
    return admin.deploy(Controller, address_provider)


def test_upgrade_controller(newController, controller, meroProxyAdmin, admin):
    meroProxyAdmin.upgrade(controller, newController, {"from": admin})


@pytest.fixture(scope="module")
def newInflationManager(MockInflationManager, admin, address_provider):
    return admin.deploy(MockInflationManager, address_provider)


def test_upgrade_inflation_manager(newInflationManager, inflation_manager, meroProxyAdmin, admin):
    meroProxyAdmin.upgrade(inflation_manager, newInflationManager, {"from": admin})


@pytest.fixture(scope="module")
def newRoleManager(admin, RoleManager, address_provider):
    return admin.deploy(RoleManager, address_provider)


def test_upgrade_role_manager(newRoleManager, role_manager, meroProxyAdmin, admin):
    meroProxyAdmin.upgrade(role_manager, newRoleManager, {"from": admin})


@pytest.fixture(scope="module")
def newAddressProvider(admin, AddressProvider):
    return admin.deploy(AddressProvider)


def test_upgrade_address_provider(newAddressProvider, address_provider, meroProxyAdmin, admin):
    meroProxyAdmin.upgrade(address_provider, newAddressProvider, {"from": admin})
