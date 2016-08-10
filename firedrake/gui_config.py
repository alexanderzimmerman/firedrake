"""A GUI for setting parameters"""

from __future__ import absolute_import

from Tkinter import *
from ttk import *

__all__ = ['show_config_gui']


def show_config_gui(parameters):
    from firedrake import Parameters

    if not isinstance(parameters, Parameters):
        raise TypeError("Expected Type: Parameters")

    def load_json():
        import tkFileDialog
        filename = tkFileDialog.askopenfilename()
        import_params_from_json(parameters, filename)

    def save_json():
        import tkFileDialog
        filename = tkFileDialog.asksaveasfilename()
        export_params_to_json(parameters, filename)

    root = Tk()

    mainframe = Frame(root, padding='3 3 12 12')
    mainframe.grid(row=0, column=0, sticky=(N, W, E, S))
    mainframe.columnconfigure(0, weight=1)
    mainframe.rowconfigure(0, weight=1)

    Button(mainframe,
           text="Load from File",
           command=load_json).grid(column=1, row=7, sticky=W)
    Button(mainframe,
           text="Save to File",
           command=save_json).grid(column=2, row=7, sticky=S)

    root.mainloop()


def export_params_to_json(parameters, filename):
    import json

    output_file = open(filename, 'w')
    output_file.write(json.dumps(parameters))
    output_file.close()


def import_params_from_json(parameters, filename):
    import json

    input_file = open(filename, 'r')
    dictionary = json.loads(input_file.read())
    input_file.close()
    load_from_dict(parameters, dictionary)
    return parameters


def load_from_dict(parameters, dictionary):
    from firedrake import Parameters

    for k in dictionary:
        if k in parameters:
            if isinstance(parameters[k], Parameters):
                load_from_dict(parameters[k], dictionary[k])
            else:
                if isinstance(dictionary[k], unicode):
                    # change unicode type to str type
                    parameters[k] = dictionary[k].encode('ascii', 'ignore')
                else:
                    parameters[k] = dictionary[k]
        else:
            print 'WARNING: ' + k + ' is not in the parameters and ignored'