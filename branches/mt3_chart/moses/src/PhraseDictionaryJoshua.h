
#pragma once

#include <map>
#include <vector>
#include <string>
#include "PhraseDictionaryMemory.h"
#include "PhraseDictionaryNode.h"
#include "ChartRuleCollection.h"
#include "../../on-disk-phrase-dict/src/Word.h"

namespace MosesOnDiskPt
{
	class SourcePhraseNode;
};

namespace Moses
{

class ChartRuleCollection;

class PhraseDictionaryJoshua : public PhraseDictionaryMemory
{
	typedef PhraseDictionaryMemory MyBase;
	friend std::ostream& operator<<(std::ostream&, const PhraseDictionaryJoshua&);

protected:
		std::string m_joshuaPath, m_sourcePath, m_targetPath, m_alignPath;
		std::vector<FactorType> m_input, m_output;
		std::vector<float> m_weight;
		float m_weightWP;

		TargetPhraseCollection *CreateTargetPhraseCollection(const Phrase &source);

public:
	PhraseDictionaryJoshua(size_t numScoreComponent)
	: MyBase(numScoreComponent)
	{}
	virtual ~PhraseDictionaryJoshua();

	bool Load(const std::vector<FactorType> &input
								, const std::vector<FactorType> &output
								, const std::string &joshuaPath
								, const std::string &sourcePath
								, const std::string &targetPath
								, const std::string &alignPath
								, const std::vector<float> &weight
								, float weightWP
								, size_t tableLimit);

	// PhraseDictionary impl
	// for mert
	void SetWeightTransModel(const std::vector<float> &weightT);
	//! find list of translations that can translates src. Only for phrase input
	virtual const TargetPhraseCollection *GetTargetPhraseCollection(const Phrase& source) const;
	//! Create entry for translation of source to targetPhrase
	virtual void AddEquivPhrase(const Phrase &source, const TargetPhrase &targetPhrase);

	virtual const ChartRuleCollection *GetChartRuleCollection(
																					InputType const& src
																					,WordsRange const& range
																					,bool adhereTableLimit) const;

	void InitializeForInput(InputType const &source);
	void CleanUp();

};

} // namespace
