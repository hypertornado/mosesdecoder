/*
 *  FeatureStats.cpp
 *  met - Minimum Error Training
 *
 *  Created by Nicola Bertoldi on 13/05/08.
 *
 */

#include <cmath>
#include <fstream>
#include "FeatureStats.h"

#define AVAILABLE_ 8;

SparseVector::name2id_t SparseVector::name2id_;
SparseVector::id2name_t SparseVector::id2name_;

FeatureStatsType SparseVector::get(string name) const {
  name2id_t::const_iterator name2id_iter = name2id_.find(name);
  if (name2id_iter == name2id_.end()) return 0;
  size_t id = name2id_iter->second;
  return get(id);

}

FeatureStatsType SparseVector::get(size_t id) const {
  fvector_t::const_iterator fvector_iter = fvector_.find(id);
  if (fvector_iter == fvector_.end()) return 0;
  return fvector_iter->second;
}

void SparseVector::set(string name, FeatureStatsType value) {
  name2id_t::const_iterator name2id_iter = name2id_.find(name);
  size_t id = 0;
  if (name2id_iter == name2id_.end()) {
    id = id2name_.size();
    id2name_.push_back(name);
    name2id_[name] = id;
  } else {
    id = name2id_iter->second;
  }
  fvector_[id] = value;
}

void SparseVector::write(ostream& out, const string& sep) const {
  for (fvector_t::const_iterator i = fvector_.begin(); i != fvector_.end(); ++i) {
    if (abs((float)(i->second)) < 0.00001) continue;
    string name = id2name_[i->first];
    out << name << sep << i->second << " ";
  }
}

void SparseVector::clear() {
  fvector_.clear();
}

size_t SparseVector::size() const {
  return fvector_.size();
}

SparseVector& SparseVector::operator-=(const SparseVector& rhs) {
  //All the elements that have values in *this
  for (fvector_t::iterator i = fvector_.begin(); i != fvector_.end(); ++i) {
    fvector_[i->first] = i->second - rhs.get(i->first);
  }

  //Any elements in rhs, that have no value in *this
  for (fvector_t::const_iterator i = rhs.fvector_.begin(); 
      i != rhs.fvector_.end(); ++i) {
    if (fvector_.find(i->first) == fvector_.end()) {
      fvector_[i->first] = -(i->second);
    }
  }
  return *this;
}

SparseVector operator-(const SparseVector& lhs, const SparseVector& rhs) {
  SparseVector res(lhs);
  res -= rhs;
  return res;
}


FeatureStats::FeatureStats()
{
  available_ = AVAILABLE_;
  entries_ = 0;
  array_ = new FeatureStatsType[available_];
};

FeatureStats::~FeatureStats()
{
  delete[] array_;
};

FeatureStats::FeatureStats(const FeatureStats &stats)
{
  available_ = stats.available();
  entries_ = stats.size();
  array_ = new FeatureStatsType[available_];
  memcpy(array_,stats.getArray(),featbytes_);
  map_ = stats.getSparse();
};

FeatureStats::FeatureStats(const size_t size)
{
  available_ = size;
  entries_ = size;
  array_ = new FeatureStatsType[available_];
  memset(array_,0,featbytes_);
};


FeatureStats::FeatureStats(std::string &theString)
{
  set(theString);
}

void FeatureStats::expand()
{
  available_*=2;
  featstats_t t_ = new FeatureStatsType[available_];
  memcpy(t_,array_,featbytes_);
  delete array_;
  array_=t_;
}

void FeatureStats::add(FeatureStatsType v)
{
  if (isfull()) expand();
  array_[entries_++]=v;
}

void FeatureStats::addSparse(string name, FeatureStatsType v)
{
  map_.set(name,v);
}

void FeatureStats::set(std::string &theString)
{
  std::string substring, stringBuf;
  reset();

  while (!theString.empty()) {
    getNextPound(theString, substring);
    // regular feature
    if (substring.find(":") == string::npos) {
      add(ATOFST(substring.c_str()));
    }
    // sparse feature
    else {
      size_t separator = substring.find_last_of(":");
      addSparse(substring.substr(0,separator), atof(substring.substr(separator+1).c_str()) );
    }
  }
}


void FeatureStats::loadbin(std::ifstream& inFile)
{
  inFile.read((char*) array_, featbytes_);
}

void FeatureStats::loadtxt(std::ifstream& inFile)
{
  std::string theString;
  std::getline(inFile, theString);
  set(theString);
}

void FeatureStats::loadtxt(const std::string &file)
{
  //	TRACE_ERR("loading the stats from " << file << std::endl);

  std::ifstream inFile(file.c_str(), std::ios::in); // matches a stream with a file. Opens the file

  loadtxt(inFile);
}


void FeatureStats::savetxt(const std::string &file)
{
//	TRACE_ERR("saving the stats into " << file << std::endl);

  std::ofstream outFile(file.c_str(), std::ios::out); // matches a stream with a file. Opens the file

  savetxt(outFile);
}


void FeatureStats::savetxt(std::ofstream& outFile)
{
//	TRACE_ERR("saving the stats" << std::endl);
  outFile << *this;
}

void FeatureStats::savebin(std::ofstream& outFile)
{
  outFile.write((char*) array_, featbytes_);
}

FeatureStats& FeatureStats::operator=(const FeatureStats &stats)
{
  delete array_;
  available_ = stats.available();
  entries_ = stats.size();
  array_ = new FeatureStatsType[available_];
  memcpy(array_,stats.getArray(),featbytes_);
  map_ = stats.getSparse();

  return *this;
}


/**write the whole object to a stream*/
ostream& operator<<(ostream& o, const FeatureStats& e)
{
  // print regular features
  for (size_t i=0; i< e.size(); i++) {
    o << e.get(i) << " ";
  }
  // sparse features
  e.getSparse().write(o,"");

  return o;
}
