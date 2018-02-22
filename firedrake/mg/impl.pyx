# Low-level numbering for multigrid support
import FIAT
from tsfc.fiatinterface import create_element

from firedrake.petsc import PETSc
import firedrake.mg.utils as utils
from firedrake import dmplex
from pyop2 import MPI
import numpy as np
cimport numpy as np
import cython
cimport petsc4py.PETSc as PETSc

np.import_array()

include "../dmplexinc.pxi"
include "firedrakeimpl.pxi"


@cython.boundscheck(False)
@cython.wraparound(False)
def get_entity_renumbering(PETSc.DM plex, PETSc.Section section, entity_type):
    """
    Given a section numbering a type of topological entity, return the
    renumberings from original plex numbers to new firedrake numbers
    (and vice versa)

    :arg plex: The DMPlex object
    :arg section: The Section defining the renumbering
    :arg entity_type: The type of entity (either ``"cell"`` or
        ``"vertex"``)
    """
    cdef:
        PetscInt start, end, p, ndof, entity
        np.ndarray[PetscInt, ndim=1] old_to_new
        np.ndarray[PetscInt, ndim=1] new_to_old

    if entity_type == "cell":
        start, end = plex.getHeightStratum(0)
    elif entity_type == "vertex":
        start, end = plex.getDepthStratum(0)
    else:
        raise RuntimeError("Entity renumbering for entities of type %s not implemented",
                           entity_type)

    old_to_new = np.empty(end - start, dtype=PETSc.IntType)
    new_to_old = np.empty(end - start, dtype=PETSc.IntType)

    for p in range(start, end):
        CHKERR(PetscSectionGetDof(section.sec, p, &ndof))
        if ndof > 0:
            CHKERR(PetscSectionGetOffset(section.sec, p, &entity))
            new_to_old[entity] = p - start
            old_to_new[p - start] = entity

    return old_to_new, new_to_old


def create_lgmap(PETSc.DM dm):
    """Create a local to global map for all points in the given DM.

    :arg dm: The DM to create the map for.

    Returns a petsc4py LGMap."""
    cdef:
        PETSc.IS iset = PETSc.IS()
        PETSc.LGMap lgmap = PETSc.LGMap()
        PetscInt *indices
        PetscInt i, size
        PetscInt start, end

    # Not necessary on one process
    if dm.comm.size == 1:
        return None
    CHKERR(DMPlexCreatePointNumbering(dm.dm, &iset.iset))
    CHKERR(ISLocalToGlobalMappingCreateIS(iset.iset, &lgmap.lgm))
    CHKERR(ISLocalToGlobalMappingGetSize(lgmap.lgm, &size))
    CHKERR(ISLocalToGlobalMappingGetBlockIndices(lgmap.lgm, <const PetscInt**>&indices))
    for i in range(size):
        if indices[i] < 0:
            indices[i] = -(indices[i]+1)

    CHKERR(ISLocalToGlobalMappingRestoreBlockIndices(lgmap.lgm, <const PetscInt**>&indices))

    return lgmap


# Exposition:
#
# These next functions compute maps from coarse mesh cells to fine
# mesh cells and provide a consistent vertex reordering of each fine
# cell inside each coarse cell.  In parallel, this is somewhat
# complicated because the DMs only provide information about
# relationships between non-overlapped meshes, and we only have
# overlapped meshes.  We there need to translate non-overlapped DM
# numbering into overlapped-DM numbering and vice versa, as well as
# translating between firedrake numbering and DM numbering.
#
# A picture is useful here to make things clearer.
#
# To translate between overlapped and non-overlapped DM points, we
# need to go via global numbers (which don't change)
#
#      DM_orig<--.    ,-<--DM_new
#         |      |    |      |
#     L2G v  G2L ^    v L2G  ^ G2L
#         |      |    |      |
#         '-->-->Global-->---'
#
# Mapping between Firedrake numbering and DM numbering is carried out
# by computing the section permutation `get_entity_renumbering` above.
#
#            .->-o2n->-.
#      DM_new          Firedrake
#            `-<-n2o-<-'
#
# Finally, coarse to fine maps are produced on the non-overlapped DM
# and subsequently composed with the appropriate sequence of maps to
# get to Firedrake numbering (and vice versa).
#
#     DM_orig_coarse
#           |
#           v coarse_to_fine_cells [coarse_cell = floor(fine_cell / 2**tdim)]
#           |
#      DM_orig_fine
#
#
#     DM_orig_coarse
#           |
#           v coarse_to_fine_vertices (via DMPlexCreateCoarsePointIS)
#           |
#      DM_orig_fine
#
# Phew.
@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def coarse_to_fine_cells(mc, mf):
    """Return a map from (renumbered) cells in a coarse mesh to those
    in a refined fine mesh.

    :arg mc: the coarse mesh to create the map from.
    :arg mf: the fine mesh to map to.
    :arg parents: a Section mapping original fine cell numbers to
         their corresponding coarse parent cells"""
    cdef:
        PETSc.DM cdm, fdm
        PetscInt fStart, fEnd, c, val, dim, nref, ncoarse
        PetscInt i, ccell, fcell, nfine
        np.ndarray[PetscInt, ndim=2, mode="c"] coarse_to_fine
        np.ndarray[PetscInt, ndim=1, mode="c"] co2n, fn2o, idx

    cdm = mc._plex
    fdm = mf._plex
    dim = cdm.getDimension()
    nref = 2 ** dim
    ncoarse = mc.cell_set.size
    nfine = mf.cell_set.size
    co2n, _ = get_entity_renumbering(cdm, mc._cell_numbering, "cell")
    _, fn2o = get_entity_renumbering(fdm, mf._cell_numbering, "cell")
    coarse_to_fine = np.empty((ncoarse, nref), dtype=PETSc.IntType)
    coarse_to_fine[:] = -1

    # Walk owned fine cells:
    fStart, fEnd = 0, nfine

    if mc.comm.size > 1:
        # Compute global numbers of original cell numbers
        mf._overlapped_lgmap.apply(fn2o, result=fn2o)
        # Compute local numbers of original cells on non-overlapped mesh
        fn2o = mf._non_overlapped_lgmap.applyInverse(fn2o, PETSc.LGMap.MapMode.MASK)
        # Need to permute order of co2n so it maps from non-overlapped
        # cells to new cells (these may have changed order).  Need to
        # map all known cells through.
        idx = np.arange(mc.cell_set.total_size, dtype=PETSc.IntType)
        # LocalToGlobal
        mc._overlapped_lgmap.apply(idx, result=idx)
        # GlobalToLocal
        # Drop values that did not exist on non-overlapped mesh
        idx = mc._non_overlapped_lgmap.applyInverse(idx, PETSc.LGMap.MapMode.DROP)
        co2n = co2n[idx]

    for c in range(fStart, fEnd):
        # get original (overlapped) cell number
        fcell = fn2o[c]
        # The owned cells should map into non-overlapped cell numbers
        # (due to parallel growth strategy)
        assert 0 <= fcell < fEnd

        # Find original coarse cell (fcell / nref) and then map
        # forward to renumbered coarse cell (again non-overlapped
        # cells should map into owned coarse cells)
        ccell = co2n[fcell // nref]
        assert 0 <= ccell < ncoarse
        for i in range(nref):
            if coarse_to_fine[ccell, i] == -1:
                coarse_to_fine[ccell, i] = c
                break
    return coarse_to_fine


@cython.boundscheck(False)
@cython.wraparound(False)
def filter_exterior_facet_labels(PETSc.DM plex):
    """Remove exterior facet labels from things that aren't facets.

    When refining, every point "underneath" the refined entity
    receives its label.  But we want the facet label to really only
    apply to facets, so clear the labels from everything else."""
    cdef:
        PetscInt pStart, pEnd, fStart, fEnd, p, value
        PetscBool has_bdy_ids, has_bdy_faces
        DMLabel exterior_facets = NULL
        DMLabel boundary_ids = NULL
        DMLabel boundary_faces = NULL

    pStart, pEnd = plex.getChart()
    fStart, fEnd = plex.getHeightStratum(1)

    # Plex will always have an exterior_facets label (maybe
    # zero-sized), but may not always have boundary_ids or
    # boundary_faces.
    has_bdy_ids = plex.hasLabel(dmplex.FACE_SETS_LABEL)
    has_bdy_faces = plex.hasLabel("boundary_faces")

    CHKERR(DMGetLabel(plex.dm, <const char*>b"exterior_facets", &exterior_facets))
    if has_bdy_ids:
        label = dmplex.FACE_SETS_LABEL.encode()
        CHKERR(DMGetLabel(plex.dm, <const char*>label, &boundary_ids))
    if has_bdy_faces:
        CHKERR(DMGetLabel(plex.dm, <const char*>b"boundary_faces", &boundary_faces))
    for p in range(pStart, pEnd):
        if p < fStart or p >= fEnd:
            CHKERR(DMLabelGetValue(exterior_facets, p, &value))
            if value >= 0:
                CHKERR(DMLabelClearValue(exterior_facets, p, value))
            if has_bdy_ids:
                CHKERR(DMLabelGetValue(boundary_ids, p, &value))
                if value >= 0:
                    CHKERR(DMLabelClearValue(boundary_ids, p, value))
            if has_bdy_faces:
                CHKERR(DMLabelGetValue(boundary_faces, p, &value))
                if value >= 0:
                    CHKERR(DMLabelClearValue(boundary_faces, p, value))
