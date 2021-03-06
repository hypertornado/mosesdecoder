#include "lm/vocab.hh"

#include "lm/binary_format.hh"
#include "lm/enumerate_vocab.hh"
#include "lm/lm_exception.hh"
#include "lm/config.hh"
#include "lm/weights.hh"
#include "util/exception.hh"
#include "util/joint_sort.hh"
#include "util/murmur_hash.hh"
#include "util/probing_hash_table.hh"

#include <string>

namespace lm {
namespace ngram {

namespace detail {
uint64_t HashForVocab(const char *str, std::size_t len) {
  // This proved faster than Boost's hash in speed trials: total load time Murmur 67090000, Boost 72210000
  // Chose to use 64A instead of native so binary format will be portable across 64 and 32 bit.  
  return util::MurmurHash64A(str, len, 0);
}
} // namespace detail

namespace {
// Normally static initialization is a bad idea but MurmurHash is pure arithmetic, so this is ok.  
const uint64_t kUnknownHash = detail::HashForVocab("<unk>", 5);
// Sadly some LMs have <UNK>.  
const uint64_t kUnknownCapHash = detail::HashForVocab("<UNK>", 5);

WordIndex ReadWords(FD fd, EnumerateVocab *enumerate) {
  if (!enumerate) return std::numeric_limits<WordIndex>::max();
  const std::size_t kInitialRead = 16384;
  std::string buf;
  buf.reserve(kInitialRead + 100);
  buf.resize(kInitialRead);
  WordIndex index = 0;
  while (true) {
#ifdef WIN32
	ssize_t got;
#else
    ssize_t got = read(fd, &buf[0], kInitialRead);
#endif
    UTIL_THROW_IF(got == -1, util::ErrnoException, "Reading vocabulary words");
    if (got == 0) return index;
    buf.resize(got);
    while (buf[buf.size() - 1]) {
      char next_char;
#ifdef WIN32
	ssize_t ret;
#else
      ssize_t ret = read(fd, &next_char, 1);
#endif
      UTIL_THROW_IF(ret == -1, util::ErrnoException, "Reading vocabulary words");
      UTIL_THROW_IF(ret == 0, FormatLoadException, "Missing null terminator on a vocab word.");
      buf.push_back(next_char);
    }
    // Ok now we have null terminated strings.  
    for (const char *i = buf.data(); i != buf.data() + buf.size();) {
      std::size_t length = strlen(i);
      enumerate->Add(index++, StringPiece(i, length));
      i += length + 1 /* null byte */;
    }
  }
}

} // namespace

WriteWordsWrapper::WriteWordsWrapper(EnumerateVocab *inner) : inner_(inner) {}
WriteWordsWrapper::~WriteWordsWrapper() {}

void WriteWordsWrapper::Add(WordIndex index, const StringPiece &str) {
  if (inner_) inner_->Add(index, str);
  buffer_.append(str.data(), str.size());
  buffer_.push_back(0);
}

void WriteWordsWrapper::Write(FD fd) {
#ifdef WIN32
#else
  if ((off_t)-1 == lseek(fd, 0, SEEK_END))
    UTIL_THROW(util::ErrnoException, "Failed to seek in binary to vocab words");
#endif
  util::WriteOrThrow(fd, buffer_.data(), buffer_.size());
}

SortedVocabulary::SortedVocabulary() : begin_(NULL), end_(NULL), enumerate_(NULL) {}

std::size_t SortedVocabulary::Size(std::size_t entries, const Config &/*config*/) {
  // Lead with the number of entries.  
  return sizeof(uint64_t) + sizeof(uint64_t) * entries;
}

void SortedVocabulary::SetupMemory(void *start, std::size_t allocated, std::size_t entries, const Config &config) {
  assert(allocated >= Size(entries, config));
  // Leave space for number of entries.  
  begin_ = reinterpret_cast<uint64_t*>(start) + 1;
  end_ = begin_;
  saw_unk_ = false;
}

void SortedVocabulary::ConfigureEnumerate(EnumerateVocab *to, std::size_t max_entries) {
  enumerate_ = to;
  if (enumerate_) {
    enumerate_->Add(0, "<unk>");
    strings_to_enumerate_.resize(max_entries);
  }
}

WordIndex SortedVocabulary::Insert(const StringPiece &str) {
  uint64_t hashed = detail::HashForVocab(str);
  if (hashed == kUnknownHash || hashed == kUnknownCapHash) {
    saw_unk_ = true;
    return 0;
  }
  *end_ = hashed;
  if (enumerate_) {
    strings_to_enumerate_[end_ - begin_].assign(str.data(), str.size());
  }
  ++end_;
  // This is 1 + the offset where it was inserted to make room for unk.  
  return end_ - begin_;
}

void SortedVocabulary::FinishedLoading(ProbBackoff *reorder_vocab) {
  if (enumerate_) {
    util::PairedIterator<ProbBackoff*, std::string*> values(reorder_vocab + 1, &*strings_to_enumerate_.begin());
    util::JointSort(begin_, end_, values);
    for (WordIndex i = 0; i < static_cast<WordIndex>(end_ - begin_); ++i) {
      // <unk> strikes again: +1 here.  
      enumerate_->Add(i + 1, strings_to_enumerate_[i]);
    }
    strings_to_enumerate_.clear();
  } else {
    util::JointSort(begin_, end_, reorder_vocab + 1);
  }
  SetSpecial(Index("<s>"), Index("</s>"), 0);
  // Save size.  Excludes UNK.  
  *(reinterpret_cast<uint64_t*>(begin_) - 1) = end_ - begin_;
  // Includes UNK.
  bound_ = end_ - begin_ + 1;
}

void SortedVocabulary::LoadedBinary(FD fd, EnumerateVocab *to) {
  end_ = begin_ + *(reinterpret_cast<const uint64_t*>(begin_) - 1);
  ReadWords(fd, to);
  SetSpecial(Index("<s>"), Index("</s>"), 0);
}

namespace {
const unsigned int kProbingVocabularyVersion = 0;
} // namespace

namespace detail {
struct ProbingVocabularyHeader {
  // Lowest unused vocab id.  This is also the number of words, including <unk>.  
  unsigned int version;
  WordIndex bound;
};
} // namespace detail

ProbingVocabulary::ProbingVocabulary() : enumerate_(NULL) {}

std::size_t ProbingVocabulary::Size(std::size_t entries, const Config &config) {
  return Align8(sizeof(detail::ProbingVocabularyHeader)) + Lookup::Size(entries, config.probing_multiplier);
}

void ProbingVocabulary::SetupMemory(void *start, std::size_t allocated, std::size_t /*entries*/, const Config &/*config*/) {
  header_ = static_cast<detail::ProbingVocabularyHeader*>(start);
  lookup_ = Lookup(static_cast<uint8_t*>(start) + Align8(sizeof(detail::ProbingVocabularyHeader)), allocated);
  bound_ = 1;
  saw_unk_ = false;
}

void ProbingVocabulary::ConfigureEnumerate(EnumerateVocab *to, std::size_t /*max_entries*/) {
  enumerate_ = to;
  if (enumerate_) {
    enumerate_->Add(0, "<unk>");
  }
}

WordIndex ProbingVocabulary::Insert(const StringPiece &str) {
  uint64_t hashed = detail::HashForVocab(str);
  // Prevent unknown from going into the table.  
  if (hashed == kUnknownHash || hashed == kUnknownCapHash) {
    saw_unk_ = true;
    return 0;
  } else {
    if (enumerate_) enumerate_->Add(bound_, str);
    lookup_.Insert(Lookup::Packing::Make(hashed, bound_));
    return bound_++;
  }
}

void ProbingVocabulary::FinishedLoading(ProbBackoff * /*reorder_vocab*/) {
  lookup_.FinishedInserting();
  header_->bound = bound_;
  header_->version = kProbingVocabularyVersion;
  SetSpecial(Index("<s>"), Index("</s>"), 0);
}

void ProbingVocabulary::LoadedBinary(FD fd, EnumerateVocab *to) {
  UTIL_THROW_IF(header_->version != kProbingVocabularyVersion, FormatLoadException, "The binary file has probing version " << header_->version << " but the code expects version " << kProbingVocabularyVersion << ".  Please rerun build_binary using the same version of the code.");
  lookup_.LoadedBinary();
  ReadWords(fd, to);
  bound_ = header_->bound;
  SetSpecial(Index("<s>"), Index("</s>"), 0);
}

void MissingUnknown(const Config &config) throw(SpecialWordMissingException) {
  switch(config.unknown_missing) {
    case SILENT:
      return;
    case COMPLAIN:
      if (config.messages) *config.messages << "The ARPA file is missing <unk>.  Substituting log10 probability " << config.unknown_missing_logprob << "." << std::endl;
      break;
    case THROW_UP:
      UTIL_THROW(SpecialWordMissingException, "The ARPA file is missing <unk> and the model is configured to throw an exception.");
  }
}

void MissingSentenceMarker(const Config &config, const char *str) throw(SpecialWordMissingException) {
  switch (config.sentence_marker_missing) {
    case SILENT:
      return;
    case COMPLAIN:
      if (config.messages) *config.messages << "Missing special word " << str << "; will treat it as <unk>.";
      break;
    case THROW_UP:
      UTIL_THROW(SpecialWordMissingException, "The ARPA file is missing " << str << " and the model is configured to reject these models.  Run build_binary -s to disable this check.");
  }
}

} // namespace ngram
} // namespace lm
