# cython: infer_types=True
# cython: profile=True
from libc.stdint cimport uint64_t
from libc.string cimport memcpy, memset

from cymem.cymem cimport Pool, Address
from murmurhash.mrmr cimport hash64

from thinc.typedefs cimport weight_t, class_t, feat_t, atom_t, hash_t, idx_t
from thinc.linear.avgtron cimport AveragedPerceptron
from thinc.linalg cimport VecVec
from thinc.structs cimport NeuralNetC, SparseArrayC, ExampleC
from thinc.structs cimport FeatureC
from thinc.extra.eg cimport Example

from preshed.maps cimport map_get
from preshed.maps cimport MapStruct

from ..structs cimport TokenC
from ._state cimport StateC
from ._parse_features cimport fill_context
from ._parse_features cimport CONTEXT_SIZE
from ._parse_features cimport fill_context
from ._parse_features cimport *
from .transition_system cimport TransitionSystem
from ..tokens.doc cimport Doc


cdef class ParserPerceptron(AveragedPerceptron):
    @property
    def widths(self):
        return (self.extracter.nr_templ,)

    def update(self, Example eg):
        '''Does regression on negative cost. Sort of cute?'''
        self.time += 1
        cdef weight_t loss = 0.0
        best = eg.best
        for clas in range(eg.c.nr_class):
            if not eg.c.is_valid[clas]:
                continue
            if eg.c.scores[clas] < eg.c.scores[best]:
                continue
            loss += (-eg.c.costs[clas] - eg.c.scores[clas]) ** 2
            d_loss = 2 * (-eg.c.costs[clas] - eg.c.scores[clas])
            step = d_loss * 0.001
            for feat in eg.c.features[:eg.c.nr_feat]:
                self.update_weight(feat.key, clas, feat.value * step)
        return int(loss)

    cdef void set_featuresC(self, ExampleC* eg, const void* _state) nogil: 
        state = <const StateC*>_state
        fill_context(eg.atoms, state)
        eg.nr_feat = self.extracter.set_features(eg.features, eg.atoms)

    def _update_from_history(self, TransitionSystem moves, Doc doc, history, weight_t grad):
        cdef Pool mem = Pool()
        cdef atom_t[CONTEXT_SIZE] context
        features = <FeatureC*>mem.alloc(self.nr_feat, sizeof(FeatureC))
        
        cdef StateClass stcls = StateClass.init(doc.c, doc.length)
        moves.initialize_state(stcls.c)

        cdef class_t clas
        self.time += 1
        for clas in history:
            fill_context(context, stcls.c)
            nr_feat = self.extracter.set_features(features, context)
            for feat in features[:nr_feat]:
                self.update_weight(feat.key, clas, feat.value * grad)
            moves.c[clas].do(stcls.c, moves.c[clas].label)
 

cdef class ParserNeuralNet(NeuralNet):
    def __init__(self, shape, **kwargs):
        vector_widths = [4] * 76
        slots =  [0, 1, 2, 3] # S0
        slots += [4, 5, 6, 7] # S1
        slots += [8, 9, 10, 11] # S2
        slots += [12, 13, 14, 15] # S3+
        slots += [16, 17, 18, 19] # B0
        slots += [20, 21, 22, 23] # B1
        slots += [24, 25, 26, 27] # B2
        slots += [28, 29, 30, 31] # B3+
        slots += [32, 33, 34, 35] * 2 # S0l, S0r
        slots += [36, 37, 38, 39] * 2 # B0l, B0r
        slots += [40, 41, 42, 43] * 2 # S1l, S1r
        slots += [44, 45, 46, 47] * 2 # S2l, S2r
        slots += [48, 49, 50, 51, 52, 53, 54, 55]
        slots += [53, 54, 55, 56]
        input_length = sum(vector_widths[slot] for slot in slots)
        widths = [input_length] + shape
        NeuralNet.__init__(self, widths, embed=(vector_widths, slots), **kwargs)

    @property
    def nr_feat(self):
        return 2000

    cdef void set_featuresC(self, ExampleC* eg, const void* _state) nogil: 
        memset(eg.features, 0, 2000 * sizeof(FeatureC))
        state = <const StateC*>_state
        fill_context(eg.atoms, state)
        feats = eg.features

        feats = _add_token(feats, 0, state.S_(0), 1.0)
        feats = _add_token(feats, 4, state.S_(1), 1.0)
        feats = _add_token(feats, 8, state.S_(2), 1.0)
        # Rest of the stack, with exponential decay
        for i in range(3, state.stack_depth()):
            feats = _add_token(feats, 12, state.S_(i), 1.0 * 0.5**(i-2))
        feats = _add_token(feats, 16, state.B_(0), 1.0)
        feats = _add_token(feats, 20, state.B_(1), 1.0)
        feats = _add_token(feats, 24, state.B_(2), 1.0)
        # Rest of the buffer, with exponential decay
        for i in range(3, min(8, state.buffer_length())):
            feats = _add_token(feats, 28, state.B_(i), 1.0 * 0.5**(i-2))
        feats = _add_subtree(feats, 32, state, state.S(0))
        feats = _add_subtree(feats, 40, state, state.B(0))
        feats = _add_subtree(feats, 48, state, state.S(1))
        feats = _add_subtree(feats, 56, state, state.S(2))
        feats = _add_pos_bigram(feats, 64, state.S_(0), state.B_(0))
        feats = _add_pos_bigram(feats, 65, state.S_(1), state.S_(0))
        feats = _add_pos_bigram(feats, 66, state.S_(1), state.B_(0))
        feats = _add_pos_bigram(feats, 67, state.S_(0), state.B_(1))
        feats = _add_pos_bigram(feats, 68, state.S_(0), state.R_(state.S(0), 1))
        feats = _add_pos_bigram(feats, 69, state.S_(0), state.R_(state.S(0), 2))
        feats = _add_pos_bigram(feats, 70, state.S_(0), state.L_(state.S(0), 1))
        feats = _add_pos_bigram(feats, 71, state.S_(0), state.L_(state.S(0), 2))
        feats = _add_pos_trigram(feats, 72, state.S_(1), state.S_(0), state.B_(0))
        feats = _add_pos_trigram(feats, 73, state.S_(0), state.B_(0), state.B_(1))
        feats = _add_pos_trigram(feats, 74, state.S_(0), state.R_(state.S(0), 1),
                                 state.R_(state.S(0), 2))
        feats = _add_pos_trigram(feats, 75, state.S_(0), state.L_(state.S(0), 1),
                                 state.L_(state.S(0), 2))
        eg.nr_feat = feats - eg.features

    cdef void _set_delta_lossC(self, weight_t* delta_loss,
            const weight_t* cost, const weight_t* scores) nogil:
        for i in range(self.c.widths[self.c.nr_layer-1]):
            delta_loss[i] = cost[i]

    cdef void _softmaxC(self, weight_t* out) nogil:
        pass

    def _update_from_history(self, TransitionSystem moves, Doc doc, history, weight_t grad):
        cdef Example py_eg = Example(nr_class=moves.n_moves, nr_atom=CONTEXT_SIZE,
                                     nr_feat=self.nr_feat, widths=self.widths)
        stcls = StateClass.init(doc.c, doc.length)
        moves.initialize_state(stcls.c)
        cdef uint64_t[2] key
        key[0] = hash64(doc.c, sizeof(TokenC) * doc.length, 0)
        key[1] = 0
        cdef uint64_t clas
        for clas in history:
            self.set_featuresC(py_eg.c, stcls.c)
            moves.set_valid(py_eg.c.is_valid, stcls.c)
            # Update with a sparse gradient: everything's 0, except our class.
            # Remember, this is a component of the global update. It's not our
            # "job" here to think about the other beam candidates. We just want
            # to work on this sequence. However, other beam candidates will
            # have gradients that refer to the same state.
            # We therefore have a key that indicates the current sequence, so that
            # the model can merge updates that refer to the same state together,
            # by summing their gradients.
            memset(py_eg.c.costs, 0, self.moves.n_moves)
            py_eg.c.costs[clas] = grad
            self.updateC(
                py_eg.c.features, py_eg.c.nr_feat, True, py_eg.c.costs, py_eg.c.is_valid,
                False, key=key[0])
            moves.c[clas].do(stcls.c, self.moves.c[clas].label)
            py_eg.c.reset()
            # Build a hash of the state sequence.
            # Position 0 represents the previous sequence, position 1 the new class.
            # So we want to do:
            # key.prev = hash((key.prev, key.new))
            # key.new = clas
            key[1] = clas
            key[0] = hash64(key, sizeof(key), 0)


cdef inline FeatureC* _add_token(FeatureC* feats,
        int slot, const TokenC* token, weight_t value) nogil:
    # Word
    feats.i = slot
    feats.key = token.lex.norm
    feats.value = value
    feats += 1
    # POS tag
    feats.i = slot+1
    feats.key = token.tag
    feats.value = value
    feats += 1
    # Dependency label 
    feats.i = slot+2
    feats.key = token.dep
    feats.value = value
    feats += 1
    # Word, label, tag
    feats.i = slot+3
    cdef uint64_t key[3]
    key[0] = token.lex.cluster
    key[1] = token.tag
    key[2] = token.dep
    feats.key = hash64(key, sizeof(key), 0)
    feats.value = value
    feats += 1
    return feats


cdef inline FeatureC* _add_subtree(FeatureC* feats, int slot, const StateC* state, int t) nogil:
    value = 1.0
    for i in range(state.n_R(t)):
        feats = _add_token(feats, slot, state.R_(t, i+1), value)
        value *= 0.5
    slot += 4
    value = 1.0
    for i in range(state.n_L(t)):
        feats = _add_token(feats, slot, state.L_(t, i+1), value)
        value *= 0.5
    return feats


cdef inline FeatureC* _add_pos_bigram(FeatureC* feat, int slot,
        const TokenC* t1, const TokenC* t2) nogil:
    cdef uint64_t[2] key
    key[0] = t1.tag
    key[1] = t2.tag
    feat.i = slot
    feat.key = hash64(key, sizeof(key), slot)
    feat.value = 1.0
    return feat+1
 

cdef inline FeatureC* _add_pos_trigram(FeatureC* feat, int slot,
        const TokenC* t1, const TokenC* t2, const TokenC* t3) nogil:
    cdef uint64_t[3] key
    key[0] = t1.tag
    key[1] = t2.tag
    key[2] = t3.tag
    feat.i = slot
    feat.key = hash64(key, sizeof(key), slot)
    feat.value = 1.0
    return feat+1
