# A bit of a lazy Hasenbusch "upgrade" to hisqhmc.nim
import qex
import mdevolve
import times,macros,json,parseopt,sequtils
import strformat,strutils,streams,os
import gauge
import layout
import gauge/[hisqsmear]
import algorithms/[integrator]
import physics/[qcdTypes,stagSolve]

export integrator
export mdevolve
export stagSolve

const banner = """
|---------------------------------------------------------------|
 Quantum EXpressions (QEX)

 QEX authors: James Osborn & Xiao-Yong Jin
 HISQ HMC authors: 
   - Curtis Taylor Peterson [C.T.P.] (Michigan State University)
   - James Osborn (Argonne National Laboratory)
   - Xiao-Yong Jin (Argonne National Laboratory) 
 QEX GitHub: https://github.com/jcosborn/qex
 C.T.P. email: curtistaylorpetersonwork@gmail.com
 cite: Proceedings of Science (PoS) LATTICE2016 (2017) 271
|---------------------------------------------------------------|
"""

const
  fileMd = "<?xml version=\"1.0\"?>\n<note>generated by QEX</note>\n"
  recordMd = "<?xml version=\"1.0\"?>\n<note>RNG field</note>\n"

const
  ActionCGTol* = 1e-20
  ForceCGTol* = 1e-12
  ActionMaxCGIter* = 10000
  ForceMaxCGIter* = 10000
  ActionCGVerbosity* = 1
  ForceCGVerbosity* = 1

# Eqn. (A2) of arXiv:1004.0342; u0 = 1.0
const
  Cp = 1.0
  Cr = -1.0/20.0

let 
  # Read from file if ReadInputs = true
  defaultInputs = %* {
    "lattice-geometry": [8,8,8,16],
    "hmc": {
      "trajectory-length": 1.0,
      "serial-rng": "milc",
      "parallel-rng": "milc",
      "serial-seed": 123456789,
      "parallel-seed": 123456789,
      "gauge-start": "cold"
    },
    "action": {
      "beta": 12.0,
      "mass": 0.001,
      "hasenbusch-mass": 0.2,
      "lepage": 0.0,
      "naik": 1.0,
      "boundary-conditions": "pppa"
    },
    "gauge": {
      "integrator": "2MN",
      "steps": 6
    },
    "fermion": {
      "integrator": "2MN",
      "steps": 2
    }
  }

type
  RNGType = enum MILC,MRG

type
  RNGRoot {.inheritable.} = object
    generator*: RNGType
    seed*: uint64
  ParallelRNG* = object of RNGRoot
    milc: typeof(Field[1,RngMilc6])
    mrg: typeof(Field[1,MRG32k3a])
  SerialRNG* = object of RNGRoot
    milc: RngMilc6
    mrg: MRG32k3a

type
  HisqHMCRoot[U] {.inheritable.} = object of RootObj
    tau: float
    hi,hf: float
    baseFilename: string
    trajs,traj0: int
    integrator: ParIntegrator
    srng*: SerialRNG
    prng*: ParallelRNG
    p,f: seq[U]
  HisqHMC*[U,F,F0] = ref object of HisqHmcRoot[U]
    beta,mass,hmass: float
    bcs: string
    u,u0: seq[U]
    su,sul: seq[U]
    phi,hphi: F
    gc: GaugeActionCoeffs
    stag: Staggered[U,F0]
    params: HisqCoefs
    spa,spf: SolverParams
    perf: PerfInfo

template UU(lo: Layout): untyped = 
  type(lo.ColorMatrix())
template FF(lo: Layout): untyped = 
  type(lo.ColorVector())
template FF0(lo: Layout): untyped = 
  type(lo.ColorVector()[0])

proc reunit*(g: auto) =
  tic()
  threads:
    let d = g.checkSU
    threadBarrier()
    echo "unitary deviation avg: ",d.avg," max: ",d.max
    g.projectSU
    threadBarrier()
    let dd = g.checkSU
    echo "new unitary deviation avg: ",dd.avg," max: ",dd.max
  toc("reunit")

#[ For construction of RNG objects ]#

proc new(
    self: var RNGRoot; 
    generator: string; 
    seed: uint64
  ) =
  case generator:
    of "milc","MILC","RngMilc6": self.generator = MILC 
    of "mrg","MRG","MRG32k3a": self.generator = MRG
    else: qexError generator, " not supported"
  self.seed = seed

proc newParallelRNG*(
    l: Layout;
    generator: string;
    seed: int;
  ): ParallelRNG =
  new(result, generator, uint64(seed))
  case result.generator:
    of MILC: result.milc = l.newRNGField(RngMilc6, result.seed)
    of MRG: result.mrg = l.newRNGField(MRG32k3a, result.seed)

proc seed(self: var SerialRNG) =
  case self.generator:
    of MILC: self.milc.seed(self.seed,987654321)
    of MRG: self.mrg.seed(self.seed,987654321)

proc newSerialRNG*(generator: string; seed: int): SerialRng =
  new(result, generator, uint64(seed))
  seed(result)

#[ For construction of HisqHMC object ]#

proc readJSON(fn: string): JsonNode = fn.parseFile

proc readCMD*: JsonNode = 
  var cmd = initOptParser()
  result = parseJson("{}")
  while true:
    cmd.next()
    case cmd.kind:
      of cmdShortOption,cmdLongOption,cmdArgument:
        try: result[cmd.key] = %* parseInt(cmd.val)
        except ValueError:
          try: result[cmd.key] = %* parseFloat(cmd.val)
          except ValueError: result[cmd.key] = %* cmd.val
      of cmdEnd: break

proc newSolverParams(r2req: float; maxits,verbosity: int): auto = 
  result = initSolverParams()
  result.r2req = r2req
  result.maxits = maxits
  result.verbosity = verbosity

proc newSolverParams(info: JsonNode; af: string): auto =
  let
    r2 = case info["fermion"].hasKey("r2-" & af)
      of true: info["fermion"]["r2-" & af].getFloat()
      of false: (if af == "action": ActionCGTol else: ForceCGTol)
    maxits = case info["fermion"].hasKey("maxits-" & af)
      of true: info["fermion"]["maxits-" & af].getInt()
      of false: (if af == "action": ActionMaxCGIter else: ForceMaxCGIter)
    verbosity = case info["fermion"].hasKey("solver-verbosity-" & af)
      of true: info["fermion"]["solver-verbosity-" & af].getInt()
      of false: (if af == "action": ActionCGVerbosity else: ForceCGVerbosity)
  result = newSolverParams(r2,maxits,verbosity)

proc newHISQ(info: JsonNode): auto = 
  result = newHISQ(
    info["action"]["lepage"].getFloat(),
    info["action"]["naik"].getFloat()
  )

proc newSerialRNG(info: JsonNode): auto =
  result = newSerialRNG(
    info["hmc"]["serial-rng"].getStr(),
    info["hmc"]["serial-seed"].getInt()
  )

proc newParallelRNG(lo: Layout; info: JsonNode): auto =
  result = lo.newParallelRNG(
    info["hmc"]["parallel-rng"].getStr(),
    info["hmc"]["parallel-seed"].getInt()
  )

proc readGauge(u: auto; fn: string) =
  if fileExists(fn):
    if 0 != u.loadGauge(fn): qexError "unable to read " & fn
    else: discard

proc readGauge*(self: var HisqHMC; fn: string) = self.u.readGauge(fn)

proc writeGauge[T](u: T; fn: string) =
  if 0 != u.saveGauge(fn): qexError "unable to write " & fn

proc writeGauge*(self: var HisqHMC; fn: string) = self.u.writeGauge(fn)

proc getIntSeq(input: JsonNode): seq[int] = 
  result = newSeq[int]()
  for elem in input.getElems(): result.add elem.getInt()

proc readSerialRNG*(self: var HisqHMC; fn: string) = self.srng.readRNG(fn)

proc readParallelRNG*(self: var HisqHMC; fn: string) = self.prng.readRNG(fn)

proc setIntegrator(info: JsonNode; field: string): IntegratorProc =
  result = toIntegratorProc(info[field]["integrator"].getStr())

proc `$`*(self: HisqHMC): string =
  let
    params = (
      trajectory_length: self.tau,
      number_of_trajectories: self.trajs,
      serial_RNG: self.srng.generator,
      parallel_RNG: self.prng.generator,
      beta: self.beta,
      mass: self.mass,
      hasenbusch_mass: self.hmass,
      cp: Cp,
      cr: Cr,
      boundary_conditions: self.bcs
    )
  for tag,val in params.fieldPairs: 
    result = result & tag.replace("_"," ") & ": " & $(val) & "\n"
  result = result & $(self.params)

template newHisqHMC*(build: untyped): auto =
  let 
    cmd = readCMD()
    info = case cmd.hasKey("json")
      of true: readJSON(cmd["json"].getStr())
      of false: defaultInputs
    lo = newLayout(info["lattice-geometry"].getIntSeq())
    fermionSteps {.inject.} = info["fermion"]["steps"].getInt()
    gaugeSteps {.inject.} = info["gauge"]["steps"].getInt()
    fermionIntegrator {.inject.} = info.setIntegrator("fermion")
    gaugeIntegrator {.inject.} = info.setIntegrator("gauge")
    start {.inject.} = info["hmc"]["gauge-start"].getStr()
  var 
    integrator {.inject.}: ParIntegrator
    hisq {.inject.} = HisqHMC[lo.UU,lo.FF,lo.FF0]()

  # Prepare HMC
  (
    hisq.tau,
    hisq.trajs,
    hisq.traj0,
    hisq.srng,
    hisq.prng,
    hisq.p,
    hisq.f
  ) = (
    info["hmc"]["trajectory-length"].getFloat(),
    (if cmd.hasKey("ntraj"): cmd["ntraj"].getInt() else: 1),
    (if cmd.hasKey("start"): cmd["start"].getInt() else: 0),
    newSerialRNG(info),
    lo.newParallelRNG(info),
    lo.newGauge(),
    lo.newGauge()
  )

  # Prepare HISQ
  let beta = info["action"]["beta"].getFloat()
  (
    hisq.beta,
    hisq.mass,
    hisq.hmass,
    hisq.bcs,
    hisq.params,
    hisq.spa,
    hisq.spf,
    hisq.gc
  ) = (
    beta,
    info["action"]["mass"].getFloat(),
    info["action"]["hasenbusch-mass"].getFloat(),
    info["action"]["boundary-conditions"].getStr(),
    newHISQ(info),
    newSolverParams(info,"action"),
    newSolverParams(info,"force"),
    GaugeActionCoeffs(plaq: beta*Cp, rect: beta*Cr)
  )

  # Prepare fields
  (
    hisq.u,
    hisq.u0,
    hisq.su,
    hisq.sul,
    hisq.phi,
    hisq.hphi
  ) = (
    lo.newGauge(),
    lo.newGauge(),
    lo.newGauge(),
    lo.newGauge(),
    lo.ColorVector(),
    lo.ColorVector()
  )
  case start:
    of "cold","frozen","symmetric": hisq.u.unit()
    of "hot","random": 
      hisq.prng.random(hisq.u) 
      hisq.u.reunit()
    else: discard
  hisq.stag = newStag3(hisq.su,hisq.sul)

  # Execute user commands and return result
  template u: untyped {.inject.} = hisq.u
  build
  hisq.integrator = integrator
  hisq

#[ Everything else... ]#

proc uniform*(self: var SerialRNG): float32 =
  case self.generator:
    of MILC: result = self.milc.uniform()
    of MRG: result = self.mrg.uniform()

proc readRNG(self: var SerialRNG; fn: string) =
  var file = newFileStream(fn, fmRead)
  if file.isNil: qexError "Was not able to read ", fn,  ". Exiting."
  else:
    case self.generator:
      of MILC: discard file.readData(self.milc.addr, self.milc.sizeof)
      of MRG: discard file.readData(self.mrg.addr, self.mrg.sizeof)

proc writeRNG(self: var SerialRNG; fn: string) =
  var file = newFileStream(fn, fmWrite)
  if file.isNil: qexError "Unable to write to ", fn,  ". Exiting."
  else:
    case self.generator:
      of MILC: file.write self.milc
      of MRG: file.write self.mrg
  file.flush

proc writeSerialRNG*(self: var HisqHMC; fn: string) = self.srng.writeRNG(fn)

proc random*(self: var ParallelRNG; u: auto) =
  case self.generator:
    of MILC: u.random(self.milc)
    of MRG: u.random(self.mrg)

proc warm*(self: var ParallelRNG; u: auto) = 
  case self.generator:
    of MILC: warm(u, 0.5, self.milc)
    of MRG: warm(u, 0.5, self.mrg)

proc readRNG(self: var ParallelRNG; filename: string) =
  case self.generator:
    of MILC:
      var reader = self.milc.l.newReader(filename)
      reader.read(self.milc)
      reader.close()
    of MRG: qexError "MRG32k3a not currently supported for IO"

proc writeRNG(self: var ParallelRNG; filename: string) =
  case self.generator:
    of MILC:
      var writer = self.milc.l.newWriter(filename, fileMd)
      writer.write(self.milc, recordMd)
      writer.close()
    of MRG: qexError "MRG32k3a not currently supported for IO"

proc writeParallelRNG*(self: var HisqHMC; fn: string) = self.prng.writeRNG(fn)

proc randomTAHGaussian(lu: auto; pRNG: auto) =
  threads:
    for mu in 0..<lu.len: lu[mu].randomTAH(pRNG)

proc randomTAHGaussian*(self: ParallelRNG; lu: auto) =
  case self.generator:
    of MILC: lu.randomTAHGaussian(self.milc)
    of MRG: lu.randomTAHGaussian(self.mrg)

proc randomComplexGaussian*(self: ParallelRNG; bosonField: auto) =
  case self.generator:
    of MILC:
      threads: bosonField.gaussian(self.milc)
    of MRG:
      threads: bosonField.gaussian(self.mrg)

template rephase(g: auto) =
  g.setBC
  threadBarrier()
  g.stagPhase

proc smearRephase(hisq: HisqCoefs; g: auto; sg,sgl: auto): auto {.discardable.} =
  threads: g.rephase
  let smearedForce = hisq.smearGetForce(g,sg,sgl)
  threads: g.rephase
  smearedForce

proc smear*(self: var HisqHMC) = 
  discard self.params.smearRephase(self.u,self.su,self.sul)

proc smearGetForce*(self: var HisqHMC): auto =
  result = self.params.smearRephase(self.u,self.su,self.sul)

proc kineticAction*[T](p: T): float =
  var p2: float
  threads:
    var p2t = 0.0
    for mu in 0..<p.len: p2t += p[mu].norm2
    threadBarrier()
    threadMaster: p2 = p2t
  result = 0.5*p2 - 16.0*float(p[0].l.physVol)

proc fermionAction*(self: HisqHMC): float =
  var 
    psi = self.u[0].l.ColorVector()
    hpsit = self.u[0].l.ColorVector()
    hpsi = self.u[0].l.ColorVector()
    fact: float
  threads: self.stag.D(hpsit,self.hphi,-self.hmass)
  self.stag.solve(psi,self.phi,-self.hmass,self.spa)
  self.stag.solve(hpsi,hpsit,-self.mass,self.spa)
  threads:
    let factt = psi.norm2() + hpsi.norm2()
    threadBarrier()
    threadMaster: fact = factt
  result = 0.5*fact 

proc hamiltonian(self: HisqHMC): float =
  let
    h = (
      kinetic: self.p.kineticAction(),
      gauge: self.gc.gaugeAction1(self.u),
      fermion: self.fermionAction()
    )
  var prnt = ""
  for tag,val in h.fieldPairs: 
    prnt = case tag
      of "fermion": prnt & tag & " = " & $(val)
      else: prnt & tag & " = " & $(val) & ", "
  echo prnt
  result = h.kinetic + h.gauge + h.fermion

proc pseudofermion(
    stag: auto; 
    phi,hphi: auto;
    psi,hpsi: auto; 
    mass,hmass: float;
    spa: var SolverParams
  ) =
  var hphit = psi.l.ColorVector()
  threads:
    stag.D(phi,psi,-hmass)
    stag.D(hphit,hpsi,-mass)
  stag.solve(hphi,hphit,-hmass,spa)
  threads:
    phi.odd := 0
    hphi.odd := 0

proc momentumHeatbath*(self: var HisqHMC) = self.prng.randomTAHGaussian(self.p)
proc fermionHeatbath*(self: var HisqHMC) =
  var 
    psi = self.u[0].l.ColorVector() 
    hpsi = self.u[0].l.ColorVector() 
  self.prng.randomComplexGaussian(hpsi)
  self.prng.randomComplexGaussian(psi)
  self.stag.pseudofermion(
    self.phi,
    self.hphi,
    psi,hpsi,
    self.mass,
    self.hmass,
    self.spa
  )

proc prepare*(self: var HisqHMC) =
  self.backup()
  self.smear()
  self.momentumHeatbath()
  self.fermionHeatbath()
  self.hi = self.hamiltonian()

proc set[T](g: auto; u: T) =
  threads:
    for mu in 0..<u.len: g[mu] := u[mu]

proc backup(self: var HisqHMC) = set(self.u0,self.u)
proc revert(self: var HisqHMC) = set(self.u,self.u0)

proc evolve*(self: var HisqHMC) = 
  self.integrator.evolve(self.tau)
  self.integrator.finish

# Temporary fix to conflict between parallel layout & multiple shifts
proc `^***`[T](shifter: auto; field: T): auto {.discardable.} = 
  const n = field[0].len
  var temp = field.newOneOf

  proc replace() =
    threads:
      for s in field:
        forO i, 0, n-1: temp[s][i] := shifter.field[s][i]

  discard shifter ^* field
  replace(); discard shifter ^* temp;
  replace(); shifter ^* temp;

proc fermionForce[S,T](
    f: auto; 
    smearedForce: proc; 
    p,hp: S; 
    g: T; 
    ffac,hfac: float
  ) =
  # reverse accumulation of the derivative
  var
    f1 = f.newOneOf()
    f3 = f.newOneOf()
    ff = f.newOneOf()
    t,t3: array[4,Shifter[typeof(p),typeof(p[0])]]
    ht,ht3: array[4,Shifter[typeof(hp),typeof(hp[0])]]

  # Prepare shifts
  for mu in 0..<f.len:
    # Single shift
    t[mu] = newShifter(p,mu,1)
    ht[mu] = newShifter(hp,mu,1)
    discard t[mu] ^* p
    discard ht[mu] ^* hp

    # Triple shift
    t3[mu] = newShifter(p,mu,3)
    ht3[mu] = newShifter(hp,mu,3)
    discard t3[mu] ^* p
    discard ht3[mu] ^* hp
    #t3[mu] = newShifter(p,mu,1)
    #ht3[mu] = newShifter(hp,mu,1)
    #discard t3[mu] ^*** p
    #discard ht3[mu] ^*** hp

  # 1. Dslash
  const n = p[0].len
  threads:
    for mu in 0..<f.len:
      for i in f[mu]:
        forO a, 0, n-1:
          forO b, 0, n-1:
            # Heavy fermion
            f1[mu][i][a,b] := ffac * p[i][a] * t[mu].field[i][b].adj
            f3[mu][i][a,b] := ffac * p[i][a] * t3[mu].field[i][b].adj

            # Hasenbusch fermion
            f1[mu][i][a,b] += hfac * hp[i][a] * ht[mu].field[i][b].adj
            f3[mu][i][a,b] += hfac * hp[i][a] * ht3[mu].field[i][b].adj

  # 2. correcting phase
  threads:
    g.rephase
    for mu in 0..<f.len:
      for i in f[mu].odd:
        f1[mu][i] *= -1
        f3[mu][i] *= -1

  # 3. smearing
  ff.smearedForce(f1,f3)

  # 4. Tₐ ReTr( Tₐ U F† )
  threads:
    for mu in 0..<f.len:
      for i in f[mu]:
        var s {.noinit.}: typeof(f[0][0])
        s := ff[mu][i] * g[mu][i].adj
        f[mu][i].projectTAH(s)
    threadBarrier()
    g.rephase

proc sq(input: float): float = input*input

proc forceSolve[T](
    stag: auto; 
    psi: auto; 
    phi: T; 
    mass: float; 
    sp: var SolverParams
  ) =
  var varphi = phi.l.ColorVector()
  stag.solveEE(varphi,phi,mass,sp)
  threads:
    varphi.even := 4.0*varphi
    threadBarrier()
    stagD2(stag.so,psi,stag.g,varphi,0,0)
    threadBarrier()
    psi.even := varphi

proc fermionForce*(self: var HisqHMC) =
  var 
    psi = self.u[0].l.ColorVector()
    hpsi = self.u[0].l.ColorVector()
  let 
    smearedForce = self.params.smearRephase(self.u,self.su,self.sul)
    ffac = 0.25
    hfac = 0.25*(self.hmass.sq-self.mass.sq)
  self.stag.forceSolve(psi,self.phi,self.hmass,self.spf)
  self.stag.forceSolve(hpsi,self.hphi,self.mass,self.spf)
  self.f.fermionForce(smearedForce,psi,hpsi,self.u,ffac,hfac)

proc gaugeForce*(self: var HisqHMC) = self.gc.gaugeForce(self.u,self.f)

proc updateGauge[T](u: auto; p: T; dtau: float) =
  threads:
    for mu in 0..<u.len:
      for s in u[mu]: u[mu][s] := exp(dtau*p[mu][s])*u[mu][s]

proc updateGauge*(self: var HisqHMC; dtau: float) =
  self.u.updateGauge(self.p,dtau)
  GC_fullCollect()

proc updateMomentum[T](p: auto; f: T; dtau: float) =
  threads:
    for mu in 0..<f.len: p[mu] -= dtau*f[mu]
  GC_fullCollect()

proc updateMomentum*(self: var HisqHMC; dtau: float) =
  self.p.updateMomentum(self.f,dtau)

proc updateMomentumFermion*(self: var HisqHMC; dtau: float) =
  self.fermionForce()
  self.updateMomentum(dtau)

proc updateMomentumGauge*(self: var HisqHMC; dtau: float) =
  self.gaugeForce()
  self.updateMomentum(dtau)

template finish*(self: var HisqHMC; input: untyped) =
  # Smear & calculate final Hamiltonian
  self.smear()
  self.hf = self.hamiltonian()
  
  # Get information accessible to user
  var 
    info {.inject.} = (dH:0.0,expdH:0.0,rnd:0.0)
    accepted {.inject.}: bool
  info.dH = self.hf - self.hi
  info.expdH = exp(-info.dH)
  info.rnd = self.srng.uniform
  accepted = info.rnd <= info.expdH
  template u: untyped {.inject.} = self.u

  # Do metropolis & have user do what they will
  case accepted:
    of true: reunit(self.u)
    of false: self.revert()
  input

proc finish*(self: var HisqHMC): bool {.discardable.} =
  self.finish: result = accepted

template sample*(self: var HisqHMC; work: untyped) =
  for traj in hmc.traj0..<hmc.trajs+hmc.traj0: 
    let trajectory {.inject.} = traj
    work

proc fermionForceCheck*(self: var HisqHMC; eps: float): float =
  proc contract[T](p,f: T): float =
    var dS: float
    threads:
      var dSt = 0.0
      for mu in 0..<p.len: dSt = dSt - reTrMul(p[mu],f[mu])
      threadMaster: dS = dSt
    result = dS
  result = eps*contract(self.p,self.f)

if isMainModule:
  # This is an example of the kind of program
  # that one could write using this code as a module
  qexInit()
  echo banner

  let 
    saveFreq = 5
    measPlaq = true
    measPoly = true
    measCond = true
    baseFilename = "checkpoint"

  # Proc for calculating plaquette
  proc plaquette[T](u: T) =
    let
      pl = u.plaq
      nl = pl.len div 2
      ps = pl[0..<nl].sum * 2.0
      pt = pl[nl..^1].sum * 2.0
      ptot = 0.5*(ps+pt)
    echo "MEASplaq ss: ",ps,"  st: ",pt,"  tot: ",ptot
  
  # Proc for calculating Polyakov loop
  proc polyakov[T](u: T) =
    let pg = u[0].l.physGeom
    var pl = newseq[typeof(u.wline @[1])](pg.len)
    for i in 0..<pg.len:
      pl[i] = u.wline repeat(i+1, pg[i])
    let
      pls = pl[0..^2].sum / float(pl.len-1)
      plt = pl[^1]
    echo "MEASploop spatial: ",pls.re," ",pls.im," temporal: ",plt.re," ",plt.im
  
  # Proc for measuring chiral condensate
  proc condensate(hmc: auto) =
    var
      pbpsp: SolverParams
      tmpa = hmc.stag.g[0].l.ColorVector()
      tmpb = hmc.stag.g[0].l.ColorVector()
    let 
      mass = hmc.mass
      vol = hmc.stag.g[0].l.physVol.float
    pbpsp.r2req = ActionCGTol
    pbpsp.maxits = ActionMaxCGIter
    threads: tmpa.u1(hmc.prng.milc)
    hmc.stag.solve(tmpb,tmpa,mass,pbpsp)
    threads:
      let pbp = tmpb.norm2
      threadMaster: echo "MEASpbp mass ",mass," : ",mass*pbp/vol

  # Construct HMC object
  var hmc = newHisqHMC:
    # Gauge link update
    proc mdt(dtau: float) = hisq.updateGauge(dtau)

    # Momentum update
    proc mdvAll(dtau: openarray[float]) =
      let (dtauG,dtauF) = (dtau[0],dtau[1])
      if (dtauG != 0.0): hisq.updateMomentumGauge(dtauG)
      if (dtauF != 0.0): hisq.updateMomentumFermion(dtauF)

    # Construct integrator according to mdEvolve scheme
    let 
      (VAll,T) = newIntegratorPair(mdvAll,mdt)
      (V,Vf) = (VAll[0],VAll[1])
    integrator = newParallelEvolution(
      gaugeIntegrator(steps = gaugeSteps, V = V, T = T),
      fermionIntegrator(steps = fermionSteps, V = Vf, T = T)
    )

    # Read information from disk
    if start == "read":
      let fn = baseFilename & "_" & $(hisq.traj0)
      hisq.readGauge(fn & ".lat")
      hisq.readSerialRNG(fn & ".serialRNG")
      hisq.readParallelRNG(fn & ".parallelRNG")
      u.plaquette
      u.polyakov
      u.reunit

  # Do HMC
  echo $(hmc)
  hmc.sample:
    hmc.prepare()
    hmc.evolve()
    hmc.finish:
      let output = $(info.dH) & ", " & $(info.expdH) & ", " & $(info.rnd)
      case accepted:
        of true: echo "ACC: ", output
        of false: echo "REJ: ", output
      if measPlaq: u.plaquette
      if measPoly: u.polyakov
      if measCond: hmc.condensate
      if (saveFreq > 0) and (((trajectory + 1) mod saveFreq) == 0):
        let fn = baseFilename & "_" & $(trajectory + 1)
        hmc.writeGauge(fn & ".lat")
        hmc.writeSerialRNG(fn & ".serialRNG")
        hmc.writeParallelRNG(fn & ".parallelRNG")

  qexFinalize()
