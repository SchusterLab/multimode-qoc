"""
picollo12.py - piccolo experiment 12
"""

from argparse import ArgumentParser
from copy import copy
import os

import autograd.numpy as anp
from filelock import FileLock
import h5py
import numpy as np
from qoc import (
    evolve_schroedinger_discrete,
    grape_schroedinger_discrete,
)
from qoc.standard import (
    Adam, LBFGSB,
    TargetStateInfidelity,
    conjugate_transpose, matmuls, krons,
    get_annihilation_operator, get_creation_operator,
    generate_save_file_path,
)

# Define paths
META_NAME = "piccolo"
EXPERIMENT_NAME = "piccolo12"
if "MULTIMODE_QOC_PATH" in os.environ:
    BASE_PATH = os.environ["MULTIMODE_QOC_PATH"]
else:
    BASE_PATH = "."
SAVE_PATH = os.path.join(BASE_PATH, "out", META_NAME, EXPERIMENT_NAME)

# Define experimental constants. All units are in GHz.
CAVITY_FREQ = 2 * np.pi * 4.4526
KAPPA = 2 * np.pi * -2.82e-6
TRANSMON_FREQ = 2 * np.pi * 5.6640
ALPHA = 2 * np.pi * -1.395126e-1
CHI_E = 2 * np.pi * -5.64453e-4
CHI_E_2 = 2 * np.pi * -7.3e-7
MAX_AMP_NORM_CAVITY = np.sqrt(2) * 2 * np.pi * 4e-4
MAX_AMP_NORM_TRANSMON = np.sqrt(2) * 2 * np.pi * 4e-3

# Define the system
CAVITY_STATE_COUNT = 3
CAVITY_ANNIHILATE = get_annihilation_operator(CAVITY_STATE_COUNT)
CAVITY_CREATE = get_creation_operator(CAVITY_STATE_COUNT)
CAVITY_NUMBER = np.matmul(CAVITY_CREATE, CAVITY_ANNIHILATE)
CAVITY_C2_A2 = matmuls(CAVITY_CREATE, CAVITY_CREATE, CAVITY_ANNIHILATE, CAVITY_ANNIHILATE)
CAVITY_ID = np.eye(CAVITY_STATE_COUNT)
CAVITY_VACUUM = np.zeros((CAVITY_STATE_COUNT, 1))
CAVITY_ZERO = np.copy(CAVITY_VACUUM)
CAVITY_ZERO[0][0] = 1
CAVITY_ONE = np.copy(CAVITY_VACUUM)
CAVITY_ONE[1][0] = 1
CAVITY_TWO = np.copy(CAVITY_VACUUM)
CAVITY_TWO[2][0] = 1

TRANSMON_STATE_COUNT = 3
TRANSMON_ANNIHILATE = get_annihilation_operator(TRANSMON_STATE_COUNT)
TRANSMON_CREATE = get_creation_operator(TRANSMON_STATE_COUNT)
TRANSMON_NUMBER = np.matmul(TRANSMON_CREATE, TRANSMON_ANNIHILATE)
TRANSMON_C2_A2 = matmuls(TRANSMON_CREATE, TRANSMON_CREATE, TRANSMON_ANNIHILATE, TRANSMON_ANNIHILATE)
TRANSMON_ID = np.eye(TRANSMON_STATE_COUNT)
TRANSMON_VACUUM = np.zeros((TRANSMON_STATE_COUNT, 1))
TRANSMON_G = np.copy(TRANSMON_VACUUM)
TRANSMON_G[0][0] = 1
TRANSMON_G_DAGGER = conjugate_transpose(TRANSMON_G)
TRANSMON_E = np.copy(TRANSMON_VACUUM)
TRANSMON_E[1][0] = 1
TRANSMON_E_DAGGER = conjugate_transpose(TRANSMON_E)
TRANSMON_F = np.copy(TRANSMON_VACUUM)
TRANSMON_F[2][0] = 1
TRANSMON_F_DAGGER = conjugate_transpose(TRANSMON_F)

H_SYSTEM = (
    # CAVITY_FREQ * krons(CAVITY_NUMBER, TRANSMON_ID)
    + (KAPPA / 2) * krons(CAVITY_C2_A2, TRANSMON_ID)
    # + TRANSMON_FREQ * krons(CAVITY_ID, TRANSMON_NUMBER)
    + (ALPHA / 2) * krons(CAVITY_ID, TRANSMON_C2_A2)
    + 2 * CHI_E * krons(CAVITY_NUMBER, np.matmul(TRANSMON_E, TRANSMON_E_DAGGER))
    + CHI_E_2 * krons(CAVITY_C2_A2, np.matmul(TRANSMON_E, TRANSMON_E_DAGGER))
)
H_CONTROL_0 = krons(CAVITY_ANNIHILATE, TRANSMON_ID)
H_CONTROL_0_DAGGER = conjugate_transpose(H_CONTROL_0)
H_CONTROL_1 = krons(CAVITY_ID, np.matmul(TRANSMON_G, TRANSMON_E_DAGGER))
H_CONTROL_1_DAGGER = conjugate_transpose(H_CONTROL_1)
H_CONTROL_2 = krons(CAVITY_ID, np.matmul(TRANSMON_E, TRANSMON_F_DAGGER))
H_CONTROL_2_DAGGER = conjugate_transpose(H_CONTROL_2)

hamiltonian = lambda controls, time: (
    H_SYSTEM
    + controls[0] * H_CONTROL_0
    + anp.conjugate(controls[0]) * H_CONTROL_0_DAGGER
    + controls[1] * H_CONTROL_1
    + anp.conjugate(controls[1]) * H_CONTROL_1_DAGGER
    + controls[2] * H_CONTROL_2
    + anp.conjugate(controls[2]) * H_CONTROL_2_DAGGER
)
CONTROL_COUNT = 3
COMPLEX_CONTROLS = True
MAX_CONTROL_NORMS = np.array((MAX_AMP_NORM_CAVITY,
                              MAX_AMP_NORM_TRANSMON,
                              MAX_AMP_NORM_TRANSMON))


# Define the problem
EVOLUTION_TIME = 1e3 #ns
CONTROL_EVAL_COUNT = SYSTEM_EVAL_COUNT = int(EVOLUTION_TIME) + 1
INITIAL_STATE_0 = krons(CAVITY_ZERO, TRANSMON_G)
INITIAL_STATES = np.stack((INITIAL_STATE_0,))
TARGET_STATE_0 = krons(CAVITY_ONE, TRANSMON_G)
TARGET_STATES = np.stack((TARGET_STATE_0,))
COSTS = (
    TargetStateInfidelity(TARGET_STATES),
)


# Define the optimization
LEARNING_RATE = 1e-3
OPTIMIZER = Adam(learning_rate=LEARNING_RATE)
ITERATION_COUNT = int(5e2)
GRAB_CONTROLS = False
if GRAB_CONTROLS:
    controls_path = os.path.join(SAVE_PATH, "00008_piccolo12.h5")
    controls_path_lock = "{}.lock".format(controls_path)
    with FileLock(controls_path_lock):
        with h5py.File(controls_path) as save_file:
            index = np.argmin(save_file["error"])
            controls = save_file["controls"][index][()]
        #ENDWITH
    #ENDWITH
    INITIAL_CONTROLS = controls
else:
    INITIAL_CONTROLS = None


# Define the output.
LOG_ITERATION_STEP = 1
SAVE_ITERATION_STEP = 1

GRAPE_CONFIG = {
    "control_count": CONTROL_COUNT,
    "control_eval_count": CONTROL_EVAL_COUNT,
    "costs": COSTS,
    "evolution_time": EVOLUTION_TIME,
    "hamiltonian": hamiltonian,
    "initial_states": INITIAL_STATES,
    "system_eval_count": SYSTEM_EVAL_COUNT,
    "complex_controls": COMPLEX_CONTROLS,
    "initial_controls": INITIAL_CONTROLS,
    "iteration_count": ITERATION_COUNT,
    "log_iteration_step": LOG_ITERATION_STEP,
    "max_control_norms": MAX_CONTROL_NORMS,
    "optimizer": OPTIMIZER,
    "save_iteration_step": SAVE_ITERATION_STEP,
}

EVOL_CONFIG = {
    "evolution_time": EVOLUTION_TIME,
    "hamiltonian": hamiltonian,
    "initial_states": INITIAL_STATES,
    "system_eval_count": SYSTEM_EVAL_COUNT,
    "controls": INITIAL_CONTROLS,
    "costs": COSTS,
}

def run_grape():
    save_file_path = generate_save_file_path(EXPERIMENT_NAME, SAVE_PATH)
    config = copy(GRAPE_CONFIG)
    config.update({
        "save_file_path": save_file_path
    })
    result = grape_schroedinger_discrete(**config)


def run_evolve():
    result = evolve_schroedinger_discrete(**EVOL_CONFIG)
    print(result.error)


def main():
    parser = ArgumentParser()
    parser.add_argument("--grape", action="store_true")
    parser.add_argument("--evolve", action="store_true")
    args = vars(parser.parse_args())
    do_grape = args["grape"]
    do_evolve = args["evolve"]

    if do_grape:
        run_grape()
    elif do_evolve:
        run_evolve()

if __name__ == "__main__":
    main()
