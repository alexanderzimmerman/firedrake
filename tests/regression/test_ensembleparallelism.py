from firedrake import *
import pytest


@pytest.mark.parallel(nprocs=6)
def test_time_allreduce():
    manager = CommManager(COMM_WORLD, 2)

    mesh = UnitSquareMesh(20, 20, comm=manager.scomm)

    x, y = SpatialCoordinate(mesh)

    V = FunctionSpace(mesh, "CG", 1)
    u_correct = Function(V)
    u = Function(V)
    usum = Function(V)

    u_correct.interpolate(sin(pi*x)*cos(pi*y) + sin(2*pi*x)*cos(2*pi*y) + sin(3*pi*x)*cos(3*pi*y))
    q = Constant(manager.ecomm.rank + 1)
    u.interpolate(sin(q*pi*x)*cos(q*pi*y))
    manager.allreduce(u, usum)

    assert assemble((u_correct - usum)**2*dx) < 1e-4


def test_comm_manager():
    with pytest.raises(ValueError):
        CommManager(COMM_WORLD, 2)


@pytest.mark.parallel(nprocs=3)
def test_comm_manager_parallel():
    with pytest.raises(ValueError):
        CommManager(COMM_WORLD, 2)


@pytest.mark.parallel(nprocs=2)
def test_comm_manager_allreduce():
    manager = CommManager(COMM_WORLD, 1)

    mesh = UnitSquareMesh(1, 1, comm=manager.scomm)

    mesh2 = UnitSquareMesh(2, 2, comm=manager.ecomm)

    V = FunctionSpace(mesh, "CG", 1)
    V2 = FunctionSpace(mesh2, "CG", 1)

    f = Function(V)
    f2 = Function(V2)

    with pytest.raises(ValueError):
        manager.allreduce(f, f2)

    f3 = Function(V2)

    with pytest.raises(ValueError):
        manager.allreduce(f3, f2)

    V3 = FunctionSpace(mesh, "DG", 0)
    g = Function(V3)
    with pytest.raises(ValueError):
        manager.allreduce(f, g)