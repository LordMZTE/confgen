cg.addString("test1.cfg", [[foo <% opt.test %> bar]])
cg.addPath(".")

cg.opt.test = "I'm a test option!"
