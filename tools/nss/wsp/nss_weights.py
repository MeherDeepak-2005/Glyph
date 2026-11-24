"""The weight program: closed-form edits to the shipped NSS weights (no training of any kind).

run.py loads keyboard/nss-english.nsslm, calls write_weights(model, **params) and scores the result
on the tune half with fasteval.py. Every edit below is a formula over the existing weights and
the keyboard dictionary's counts; no gradient, optimizer or fitting loop is allowed (program.md).

Model (numpy, see nsslm.py): one CIFG-LSTM layer.
  x = [embedding[word] (96) | h (96)]
  gates = x @ gates.T + gate_bias            forget | candidate | output, 670 each
  c' = f*c + (1-f)*tanh(candidate);  m = o*tanh(c');  h' = projection @ m   (96)
  logits = embedding @ h' + output_bias      (tied: the same 30,004 x 96 matrix)
"""
import numpy as np

from nsslm import Model, UNK

model_shorthand_name = 'on'
model_description = 'length prior on the output bias: gamma * (letters - center); optional temperature tau and <unk> shift'
PARAMS = {}

IN = 96  # gate input columns 0..95 read the word embedding, 96..191 read the recurrent h


def temperature(model: Model, tau: float) -> None:
    """Multiply every logit by tau without changing the recurrence.

    h' = tau * (projection @ m) makes the features tau times larger, so embedding @ h' is tau times
    larger; the recurrent half of the gate matrix is divided by tau so the next step sees the same
    pre-activations; the output bias is multiplied by tau. Net effect: P(w) proportional to P_old(w)^tau.
    """
    model.projection *= tau
    model.gates[:, IN:] /= tau
    model.output_bias *= tau


def unk_shift(model: Model, delta: float) -> None:
    """Move the <unk> logit: P(<unk>|context) carries every dictionary word outside the 30k
    vocabulary, the unigram floor, and the price of leaving a typed non-word as typed."""
    model.output_bias[UNK] += delta


def length_prior(model: Model, gamma: float, center: float, hinge: float = 0) -> None:
    """Add gamma * (letters - center) to every word's output bias (not the specials or <unk>).

    A word typed with a mistake is more often a long word than the language model alone expects:
    every letter is another chance to hit a wrong key, and short words are typed by heart. On the
    tune half the words wrongly committed in place of names and Tenglish average 4.4-4.8 letters,
    while the misspellings left uncorrected are of 9.2-letter words. With hinge, only the letters
    beyond `center` count, so short words keep their probability next to <unk> and the unigram floor.
    """
    letters = np.array([len(w.replace("'", "")) for w in model.words], np.float32)
    over = letters - center
    shift = gamma * (np.maximum(over, 0) if hinge else over); shift[:4] = 0; shift[UNK] = 0
    model.output_bias += shift


def apostrophe_prior(model: Model, beta: float) -> None:
    """Add beta to the output bias of every word spelled with an apostrophe (don't, i'm, it's).

    The model learned from edited text where contractions always carry their apostrophe; on a
    phone keyboard the apostrophe is on another layer and is usually left out, so a typed `dont`
    must reach `don't` through a deletion the keyboard prices at 1.1 (4.4 nats of score).
    """
    model.output_bias += beta * np.array(["'" in w.strip("'") for w in model.words], np.float32)


def write_weights(model: Model, tau: float = 1.0, unk: float = 0.0, gamma: float = 0.0, center: float = 6.0, hinge: float = 0,
                  beta: float = 0.0) -> Model:
    if tau != 1.0: temperature(model, tau)
    if unk: unk_shift(model, unk)
    if gamma: length_prior(model, gamma, center, hinge)
    if beta: apostrophe_prior(model, beta)
    return model
